package TestSequenceMemory32;

import Vector::*;
import MorbiusTypes::*;
import MorbiusMemory::*;

function Symbol patternSymbol(Bit#(10) position);
	return truncate(position ^ (position >> 3) ^ (position >> 6));
endfunction

(* synthesize *)
module mkTestSequenceMemory32(Empty);
	SequenceMemoryIfc profiler <- mkSequenceMemory;
	MotifSequenceMemoryIfc motif <- mkMotifSequenceMemory;
	Reg#(Bit#(5)) loadCnt <- mkReg(0);
	Reg#(Bool) loadedR <- mkReg(False);
	Reg#(UInt#(12)) sentCnt <- mkReg(0);
	Reg#(UInt#(12)) receivedCnt <- mkReg(0);
	Reg#(Bool) serialOn <- mkReg(False);
	Reg#(Bool) pendingR <- mkReg(False);
	Reg#(UInt#(9)) serialCnt <- mkReg(0);
	Reg#(Bit#(10)) serialPositionR <- mkReg(0);
	Reg#(UInt#(32)) cycleCnt <- mkReg(0);

	rule tick;
		cycleCnt <= cycleCnt + 1;
		if ( cycleCnt == 30000 ) begin
			$display("FAIL: sequence memory timeout");
			$finish(1);
		end
	endrule

	rule load1 ( loadCnt < 16 );
		Bit#(512) word = 0;
		for ( Integer i = 0; i < 64; i = i + 1 ) begin
			Bit#(10) position = (zeroExtend(loadCnt) << 6) + fromInteger(i);
			Bit#(8) encoded = zeroExtend(patternSymbol(position));
			Integer low = i * 8;
			word[low + 7:low] = encoded;
		end
		profiler.loadBeat(truncate(loadCnt), word);
		motif.loadBeat(truncate(loadCnt), word);
		loadCnt <= loadCnt + 1;
	endrule

	rule loaded1 ( !loadedR && loadCnt == 16 && profiler.loadIdle && motif.loadIdle );
		loadedR <= True;
	endrule

	rule request1 ( loadedR && !serialOn && sentCnt < 1024 );
		Bit#(11) position = truncate(pack(sentCnt));
		profiler.readWindow(position);
		motif.readWindow(position);
		sentCnt <= sentCnt + 1;
	endrule

	rule response1 ( loadedR && !serialOn && receivedCnt < 1024 );
		let actual <- profiler.getWindow;
		let motifActual <- motif.getWindow;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			Bit#(10) position = truncate(pack(receivedCnt)) + fromInteger(i);
			if ( actual[i] != patternSymbol(position) ) begin
				$display("FAIL: streamed Profiler position=%0d lane=%0d", receivedCnt, i);
				$finish(1);
			end
		end
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			Bit#(10) position = truncate(pack(receivedCnt)) + fromInteger(i);
			if ( motifActual[i] != patternSymbol(position) ) begin
				$display("FAIL: four-symbol motif position=%0d lane=%0d", receivedCnt, i);
				$finish(1);
			end
		end
		receivedCnt <= receivedCnt + 1;
		if ( receivedCnt == 1023 ) serialOn <= True;
	endrule

	// Pause the consumer with one outstanding read, then resume with a new address.
	rule request2 ( loadedR && serialOn && !pendingR && serialCnt < 256 );
		UInt#(16) index = zeroExtend(serialCnt) * 37;
		Bit#(10) position = truncate(pack(index));
		profiler.readWindow(zeroExtend(position));
		motif.readWindow(zeroExtend(position));
		serialPositionR <= position;
		pendingR <= True;
	endrule

	rule response2 ( serialOn && pendingR && cycleCnt % 7 == 0 );
		let actual <- profiler.getWindow;
		let motifActual <- motif.getWindow;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			Bit#(10) position = serialPositionR + fromInteger(i);
			if ( actual[i] != patternSymbol(position) ) begin
				$display("FAIL: stalled Profiler position=%0d lane=%0d", serialPositionR, i);
				$finish(1);
			end
		end
		for ( Integer i = 0; i < valueOf(NumPE_LPM); i = i + 1 ) begin
			Bit#(10) position = serialPositionR + fromInteger(i);
			if ( motifActual[i] != patternSymbol(position) ) begin
				$display("FAIL: stalled motif position=%0d lane=%0d", serialPositionR, i);
				$finish(1);
			end
		end
		pendingR <= False;
		serialCnt <= serialCnt + 1;
		if ( serialCnt == 255 ) begin
			$display("PASS: 1024 streamed and 256 paused windows, all 32 lanes, row/beat boundaries and motif path");
			$finish(0);
		end
	endrule
endmodule

endpackage
