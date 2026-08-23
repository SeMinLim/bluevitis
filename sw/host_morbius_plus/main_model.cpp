#include "MorbiusPlus.h"

#include <stdio.h>


int main( int argc, char **argv ) {
	Config config;
	parseArguments(argc, argv, &config);
	if ( config.useModel == false ) {
		printf( "The model executable requires --model.\n" );
		return 1;
	}
	resetModelKernel();
	return runMorbiusPlusApplication(&config, executeModelKernel, NULL);
}
