#ifndef MORBIUSPLUS_H
#define MORBIUSPLUS_H

#include <stddef.h>
#include <stdint.h>

#include <string>
#include <vector>


#define ALPHABET_DNA 0
#define ALPHABET_PROTEIN 1

#define SAMPLEMAX 256
#define ANCHORMAX 8
#define DNASEEDMAX 8
#define PROTEINSEEDMAX 3
#define PSEUDOCOUNT 1
#define RANDOMFRACTIONBITS 24
#define DEFAULTMAXSWEEPNUM 20
#define DEFAULTSCORETHRESHOLD 0.90
#define DEFAULTSEED 1
#define DEFAULTBATCHSIZE 256
#define DNAENTROPYMIN 1.20

#define ACCELMAXPIPELINE 16
#define ACCELMAXSEQUENCELENGTH 1024
#define ACCELMAXMOTIFLENGTH 128
#define ACCELALPHABETMAX 20
#define ACCELSEGMENTSIZE 16
#define ACCELCOMMANDMAGIC 0x4d504c53U
#define ACCELRESULTMAGIC 0x4d50524cU
#define ACCELPROTOCOLVERSION 2
#define ACCELCOMMAND_BOOTSTRAP 0
#define ACCELCOMMAND_BATCH 1
#define ACCELBEATBYTES 64
#define ACCELPIPELINEPERRESULTBEAT 4
#define ACCELRESULTBEATNUM (ACCELMAXPIPELINE / ACCELPIPELINEPERRESULTBEAT)
#define ACCELRESULTBYTES (ACCELRESULTBEATNUM * ACCELBEATBYTES)


typedef struct Config {
	std::string inputFilename;
	std::string outputPrefix;
	std::string xclbinFilename;
	int alphabetMode;
	size_t motifLength;
	uint64_t maxUpdateNum;
	double scoreThreshold;
	uint64_t randomSeed;
	int threadNum;
	int deviceId;
	size_t batchSize;
	bool useModel;
}Config;

typedef struct Dataset {
	std::vector<std::string> names;
	std::vector<std::string> sequences;
	std::string alphabet;
	std::vector<int> symbolMap;
	size_t sequenceLength;
	int alphabetSize;
}Dataset;

typedef struct RandomGenerator {
	uint32_t state[4];
}RandomGenerator;

typedef struct MarkovModel {
	int order;
	int alphabetSize;
	uint64_t contextTotal;
	std::vector<uint64_t> contextCount;
	std::vector<uint64_t> transitionCount;
}MarkovModel;

typedef struct SeedModel {
	bool valid;
	size_t sampleNum;
	size_t seedLength;
	uint32_t seedCode;
	std::string seedString;
	uint32_t seedSupport;
	double seedExpectedSupport;
	double seedRank;
	size_t anchorOffset;
	double anchorRank;
	std::vector<std::vector<uint32_t>> guidedOffsets;
}SeedModel;

typedef struct PipelineResult {
	std::vector<uint32_t> bestOffsets;
	uint64_t bestScore;
	uint64_t updateNum;
	bool thresholdReached;
	double elapsedTime;
}PipelineResult;

typedef struct AccelWireResult {
	uint32_t newOffset;
	uint32_t bestScore;
	uint32_t updateNum;
	bool bestUpdate;
	bool terminated;
	bool active;
}AccelWireResult;

typedef struct AccelSummary {
	uint32_t processedNum;
	uint32_t cycleNum;
	bool allDone;
	int bestPipelineIdx;
	uint32_t bestScore[ACCELMAXPIPELINE];
	bool terminated[ACCELMAXPIPELINE];
}AccelSummary;

typedef struct AccelPipelineHostState {
	std::vector<uint32_t> offsets;
	std::vector<uint32_t> bestOffsets;
	std::vector<uint32_t> initialBPM;
	std::vector<uint32_t> initialLPMQ12;
	RandomGenerator randomGenerator;
	uint32_t bestScore;
	uint32_t updateNum;
	bool terminated;
}AccelPipelineHostState;

typedef int (*KernelExecutor)( const std::vector<uint8_t> &input,
			       size_t outputSize,
			       std::vector<uint8_t> &output,
			       void *context );

int runMorbiusPlusApplication( Config *config,
			       KernelExecutor executor,
			       void *executorContext );

double timeChecker( void );
uint64_t integerPower( uint64_t base, size_t exponent );
void initializeRandomGenerator( RandomGenerator *randomGenerator, uint64_t seed );
uint32_t randomWord( RandomGenerator *randomGenerator );
uint32_t randomQ24( RandomGenerator *randomGenerator );
double randomUnit( RandomGenerator *randomGenerator );
uint32_t randomBounded( RandomGenerator *randomGenerator, uint32_t bound );
void parseArguments( int argc, char **argv, Config *config );
void configureAlphabet( int alphabetMode, Dataset *dataset );
void readFASTA( const std::string &filename, Dataset *dataset );
void validateWorkload( const Config *config, const Dataset *dataset );
uint32_t encodeKmer( const std::string &sequence,
		     size_t position,
		     size_t kmerLength,
		     const Dataset *dataset );

void buildSeedModel( const Config *config, const Dataset *dataset, SeedModel *seedModel );
void initializeOffsets( const Config *config,
			const Dataset *dataset,
			const SeedModel *seedModel,
			int pipelineIdx,
			std::vector<uint32_t> &offsets );

void buildBPM( const Config *config,
	       const Dataset *dataset,
	       const std::vector<uint32_t> &offsets,
	       std::vector<uint32_t> &bpm );
void buildLPMQ12( const std::vector<uint32_t> &bpm, std::vector<uint32_t> &lpmQ12 );
uint32_t calculateLog2PWLQ12( uint32_t count );
uint32_t calculateExp2PWLQ18( uint32_t differenceQ12 );
uint64_t calculateConsensusScore( const Config *config,
				  const Dataset *dataset,
				  const std::vector<uint32_t> &bpm );
double calculateNormalizedScore( const Config *config,
				 const Dataset *dataset,
				 uint64_t score );
uint64_t calculateRawScoreThreshold( const Config *config, const Dataset *dataset );

void buildBootstrapCommand( const Config *config,
			    const Dataset *dataset,
			    const std::vector<AccelPipelineHostState> &pipelineStates,
			    std::vector<uint8_t> &input );
void buildBatchCommand( const Config *config,
			const Dataset *dataset,
			const std::vector<AccelPipelineHostState> &pipelineStates,
			size_t sequenceStart,
			size_t sequenceNum,
			std::vector<uint8_t> &input );
void parseResultBeat( const uint8_t *beat,
		      std::vector<AccelWireResult> &results );
void parseSummaryBeat( const uint8_t *beat, AccelSummary *summary );

int executeModelKernel( const std::vector<uint8_t> &input,
			size_t outputSize,
			std::vector<uint8_t> &output,
			void *context );
void resetModelKernel( void );

void runAccelerator( const Config *config,
		     const Dataset *dataset,
		     const SeedModel *seedModel,
		     KernelExecutor executor,
		     void *executorContext,
		     std::vector<PipelineResult> &pipelineResults );
int selectBestPipeline( const std::vector<PipelineResult> &pipelineResults );

void buildResultCount( const Config *config,
		       const Dataset *dataset,
		       const std::vector<uint32_t> &offsets,
		       std::vector<uint32_t> &count );
std::string buildConsensus( const Config *config,
			    const Dataset *dataset,
			    const std::vector<uint32_t> &count );
void createOutputDirectory( const std::string &outputPrefix );
void writeMotifFASTA( const Config *config,
		      const Dataset *dataset,
		      const std::vector<uint32_t> &offsets );
void writeOffsets( const Config *config,
		   const Dataset *dataset,
		   const std::vector<uint32_t> &offsets );
void writePWM( const Config *config,
	       const Dataset *dataset,
	       const std::vector<uint32_t> &count );
void writeMEME( const Config *config,
		const Dataset *dataset,
		const std::vector<uint32_t> &count );
void writeSummary( const Config *config,
		   const Dataset *dataset,
		   const SeedModel *seedModel,
		   const std::vector<PipelineResult> &pipelineResults,
		   int bestPipelineIdx,
		   const std::string &consensus,
		   double elapsedTime );
void printResult( const Config *config,
		  const Dataset *dataset,
		  const SeedModel *seedModel,
		  const std::vector<PipelineResult> &pipelineResults,
		  int bestPipelineIdx,
		  const std::string &consensus,
		  double elapsedTime );

#endif
