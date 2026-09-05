#include "MorbiusPlus.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>


typedef struct TraceContext {
	FILE *input;
	FILE *output;
	FILE *commands;
}TraceContext;

static void writeWords( FILE *file, const std::vector<uint8_t> &bytes ) {
	if ( bytes.size() % ACCELBEATBYTES != 0 ) {
		printf( "Trace buffer is not beat aligned.\n" );
		exit(1);
	}
	for ( size_t offset = 0; offset < bytes.size(); offset += ACCELBEATBYTES ) {
		for ( size_t i = ACCELBEATBYTES; i > 0; i -- ) {
			if ( fprintf(file, "%02x", (unsigned int)bytes[offset + i - 1]) < 0 ) exit(1);
		}
		if ( fputc('\n', file) == EOF ) exit(1);
	}
}

static int executeTrace( const std::vector<uint8_t> &input,
			 size_t outputSize,
			 std::vector<uint8_t> &output,
			 void *contextValue ) {
	TraceContext *context = (TraceContext*)contextValue;
	int status = executeModelKernel(input, outputSize, output, NULL);
	if ( status != 0 ) return status;
	writeWords(context->input, input);
	writeWords(context->output, output);
	if ( fprintf(context->commands, "%08x%08x\n",
		     (unsigned int)(input.size() / ACCELBEATBYTES),
		     (unsigned int)(output.size() / ACCELBEATBYTES)) < 0 ) return 1;
	return 0;
}

int main( int argc, char **argv ) {
	Config config;
	parseArguments(argc, argv, &config);
	TraceContext context;
	context.input = fopen("input.hex", "w");
	context.output = fopen("expected.hex", "w");
	context.commands = fopen("commands.hex", "w");
	if ( context.input == NULL || context.output == NULL || context.commands == NULL ) {
		printf( "Unable to open RTL trace files.\n" );
		return 1;
	}
	resetModelKernel();
	int status = runMorbiusPlusApplication(&config, executeTrace, &context);
	if ( fprintf(context.commands, "0000000000000000\n") < 0 ) status = 1;
	if ( fclose(context.input) != 0 ) status = 1;
	if ( fclose(context.output) != 0 ) status = 1;
	if ( fclose(context.commands) != 0 ) status = 1;
	return status;
}
