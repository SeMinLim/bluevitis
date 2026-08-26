package TestGibbsPipeline;

import Vector::*;

import MorbiusTypes::*;
import GibbsPipeline::*;


typedef enum {
	TEST_CONFIGURE,
	TEST_LOAD_SEQUENCE,
	TEST_LOAD_MATRIX,
	TEST_START_BOOTSTRAP,
	TEST_WAIT_BOOTSTRAP,
	TEST_START_UPDATE,
	TEST_WAIT_UPDATE,
	TEST_DONE
} TestState deriving (Bits, Eq, FShow);

function Bit#(512) buildSequenceWord;
	Bit#(512) word = 0;
	for ( Integer i = 0; i < 16; i = i + 1 ) begin
		Bit#(5) symbol = fromInteger(i % 4);
		word = word | (zeroExtend(symbol) << (i * 8));
	end
	return word;
endfunction

function MatrixColumn buildBpmColumn(Bit#(5) favoredSymbol);
	MatrixColumn word = 0;
	for ( Integer i = 0; i < 20; i = i + 1 ) begin
		UInt#(18) count = 1;
		if ( fromInteger(i) == favoredSymbol ) count = 8;
		word = setMatrixEntry(word, fromInteger(i), count);
	end
	return word;
endfunction

function MatrixColumn buildLpmColumn(Bit#(5) favoredSymbol);
	MatrixColumn word = 0;
	for ( Integer i = 0; i < 20; i = i + 1 ) begin
		UInt#(18) value = 0;
		if ( fromInteger(i) == favoredSymbol ) value = 3 << 12;
		word = setMatrixEntry(word, fromInteger(i), value);
	end
	return word;
endfunction

(* synthesize *)
module mkTestGibbsPipeline(Empty);
	GibbsPipelineIfc pipeline <- mkGibbsPipeline;
	Reg#(TestState) stateR <- mkReg(TEST_CONFIGURE);
	Reg#(Bit#(8)) columnR <- mkReg(0);
	Reg#(UInt#(32)) cycleR <- mkReg(0);
	Reg#(UInt#(32)) bootstrapScoreR <- mkReg(0);

	rule countCycle;
		cycleR <= cycleR + 1;
	endrule

	rule configure1 ( stateR == TEST_CONFIGURE );
		pipeline.configure(PipelineConfig{
			sequenceLength: 16,
			motifLength: 4,
			alphabetSize: 4,
			scoreThreshold: 1000,
			maxUpdates: 2
			},
		128'h0123456789abcdef0011223344556677,
		32,
		True);
		stateR <= TEST_LOAD_SEQUENCE;
	endrule

	rule loadSequence1 ( stateR == TEST_LOAD_SEQUENCE );
		pipeline.loadSequenceBeat(0, buildSequenceWord);
		columnR <= 0;
		stateR <= TEST_LOAD_MATRIX;
	endrule

	rule loadMatrix1 ( stateR == TEST_LOAD_MATRIX );
		Bit#(5) favoredSymbol = truncate(columnR);
		pipeline.loadBpmColumn(columnR, buildBpmColumn(favoredSymbol));
		pipeline.loadLpmColumn(columnR, buildLpmColumn(favoredSymbol));
		if ( columnR == 3 ) stateR <= TEST_START_BOOTSTRAP;
		else columnR <= columnR + 1;
	endrule

	rule startBootstrap1 ( stateR == TEST_START_BOOTSTRAP );
		pipeline.startBootstrap;
		stateR <= TEST_WAIT_BOOTSTRAP;
	endrule

	rule waitBootstrap1 ( stateR == TEST_WAIT_BOOTSTRAP );
		let result <- pipeline.result;
		$display("Bootstrap offset=%0d score=%0d update=%0d bestUpdate=%0d terminated=%0d cycle=%0d",
			 result.newOffset,
			 result.bestScore,
			 result.updateNum,
			 result.bestUpdate,
			 result.terminated,
			 cycleR);
		if ( result.newOffset > 12 || result.bestScore < 32 ||
		     result.updateNum != 1 || result.terminated ) begin
			$display("TEST FAILED: unexpected bootstrap result");
			$finish(1);
		end
		bootstrapScoreR <= result.bestScore;
		stateR <= TEST_START_UPDATE;
	endrule

	rule startUpdate1 ( stateR == TEST_START_UPDATE );
		pipeline.startUpdate(0);
		stateR <= TEST_WAIT_UPDATE;
	endrule

	rule waitUpdate1 ( stateR == TEST_WAIT_UPDATE );
		let result <- pipeline.result;
		$display("Update offset=%0d score=%0d update=%0d bestUpdate=%0d terminated=%0d cycle=%0d",
			 result.newOffset,
			 result.bestScore,
			 result.updateNum,
			 result.bestUpdate,
			 result.terminated,
			 cycleR);
		if ( result.newOffset > 12 || result.bestScore < bootstrapScoreR ||
		     result.updateNum != 2 || !result.terminated ) begin
			$display("TEST FAILED: unexpected update result");
			$finish(1);
		end
		$display("All GibbsPipeline tests passed.");
		stateR <= TEST_DONE;
		$finish(0);
	endrule
endmodule

endpackage
