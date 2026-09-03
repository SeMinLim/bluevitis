package TestGibbsPipeline;

import Vector::*;

import GibbsPipeline::*;
import MorbiusTypes::*;


typedef enum {
	TEST_CONFIGURE,
	TEST_CONFIGURE_PIPELINE,
	TEST_LOAD_MATRIX,
	TEST_LOAD_SEQUENCE,
	TEST_START,
	TEST_WAIT,
	TEST_DONE
} TestState deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTestGibbsPipeline(Empty);
	GibbsPipelineArrayIfc pipelineArray <- mkGibbsPipelineArray;
	Reg#(TestState) stateR <- mkReg(TEST_CONFIGURE);
	Reg#(Bit#(PipelineIndexWidth)) pipelineIdxR <- mkReg(0);
	Reg#(UInt#(16)) cycleCntR <- mkReg(0);

	rule incrementCycle;
		cycleCntR <= cycleCntR + 1;
	endrule

	rule configure1 ( stateR == TEST_CONFIGURE );
		pipelineArray.configure(PipelineConfig{
			sequenceLength: 16,
			motifLength: 4,
			alphabetSize: 4,
			scoreThreshold: 100,
			maxUpdates: 2
			});
		pipelineIdxR <= 0;
		stateR <= TEST_CONFIGURE_PIPELINE;
	endrule

	rule configurePipeline1 ( stateR == TEST_CONFIGURE_PIPELINE );
		Bit#(128) seedValue = zeroExtend(pipelineIdxR) + 1;
		pipelineArray.configurePipeline(pipelineIdxR, seedValue, 0);
		if ( pipelineIdxR == fromInteger(valueOf(NumPipeline) - 1) ) begin
			pipelineIdxR <= 0;
			stateR <= TEST_LOAD_MATRIX;
		end else begin
			pipelineIdxR <= pipelineIdxR + 1;
		end
	endrule

	rule loadMatrix1 ( stateR == TEST_LOAD_MATRIX );
		BpmEntries bpmColumn = replicate(1);
		LpmEntries lpmColumn = replicate(0);
		BpmGroup bpmGroup = replicate(bpmColumn);
		LpmGroup lpmGroup = replicate(lpmColumn);
		pipelineArray.loadBpmGroup(pipelineIdxR, 0, bpmGroup);
		pipelineArray.loadLpmGroup(pipelineIdxR, 0, lpmGroup);
		if ( pipelineIdxR == fromInteger(valueOf(NumPipeline) - 1) ) begin
			stateR <= TEST_LOAD_SEQUENCE;
		end else begin
			pipelineIdxR <= pipelineIdxR + 1;
		end
	endrule

	rule loadSequence1 ( stateR == TEST_LOAD_SEQUENCE );
		Bit#(512) word = 0;
		for ( Integer i = 0; i < 16; i = i + 1 ) begin
			Integer low = i * 8;
			word[low + 7:low] = fromInteger(i % 4);
		end
		pipelineArray.loadSequenceBeat(0, word);
		stateR <= TEST_START;
	endrule

	rule start1 ( stateR == TEST_START );
		pipelineArray.startBootstrap;
		stateR <= TEST_WAIT;
	endrule

	rule wait1 ( stateR == TEST_WAIT );
		let result <- pipelineArray.result;
		Bool valid = True;
		for ( Integer i = 0; i < valueOf(NumPipeline); i = i + 1 ) begin
			valid = valid && result[i].newOffset <= 12;
			valid = valid && result[i].updateNum == 1;
			valid = valid && result[i].bestScore == 8;
		end
		if ( valid ) begin
			$display("Morbius+ Gibbs array test passed in %0d cycles.", cycleCntR);
		end else begin
			$display("Morbius+ Gibbs array test failed.");
			$finish(1);
		end
		stateR <= TEST_DONE;
	endrule

	rule finish1 ( stateR == TEST_DONE );
		$finish(0);
	endrule
endmodule

endpackage
