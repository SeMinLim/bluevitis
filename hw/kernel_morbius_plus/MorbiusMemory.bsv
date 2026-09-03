package MorbiusMemory;

import FIFOF::*;
import Vector::*;

import MorbiusTypes::*;
import SdpMemory::*;


//------------------------------------------------------------------------------------
// Four-column BPM storage in simple-dual-port block RAM
//------------------------------------------------------------------------------------
interface BpmMemoryIfc;
	method Action loadGroup(Bit#(5) address, BpmGroup value);
	method Action readGroup(Bit#(5) address);
	method BpmGroup readResponse;
	method Action writeGroup(Bit#(5) address, BpmGroup value);
endinterface

module mkBpmMemory(BpmMemoryIfc);
	SdpMemoryIfc#(Bit#(5), BpmGroup) memory <-
		mkSdpMemory(valueOf(MotifGroupDepth));

	method Action loadGroup(Bit#(5) address, BpmGroup value);
		memory.write(address, value);
	endmethod

	method Action readGroup(Bit#(5) address);
		memory.readRequest(address);
	endmethod

	method BpmGroup readResponse;
		return memory.readResponse;
	endmethod

	method Action writeGroup(Bit#(5) address, BpmGroup value);
		memory.write(address, value);
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Four-column LPM storage in simple-dual-port block RAM
//------------------------------------------------------------------------------------
interface LpmMemoryIfc;
	method Action loadGroup(Bit#(5) address, LpmGroup value);
	method Action readGroup(Bit#(5) address);
	method LpmGroup readResponse;
	method Action writeGroup(Bit#(5) address, LpmGroup value);
endinterface

module mkLpmMemory(LpmMemoryIfc);
	SdpMemoryIfc#(Bit#(5), LpmGroup) memory <-
		mkSdpMemory(valueOf(MotifGroupDepth));

	method Action loadGroup(Bit#(5) address, LpmGroup value);
		memory.write(address, value);
	endmethod

	method Action readGroup(Bit#(5) address);
		memory.readRequest(address);
	endmethod

	method LpmGroup readResponse;
		return memory.readResponse;
	endmethod

	method Action writeGroup(Bit#(5) address, LpmGroup value);
		memory.write(address, value);
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Four-symbol tentative-motif storage
//------------------------------------------------------------------------------------
interface MotifMemoryIfc;
	method Action readGroup(Bit#(5) address);
	method MotifSymbolGroup readResponse;
	method Action writeGroup(Bit#(5) address, MotifSymbolGroup value);
endinterface

module mkMotifMemory(MotifMemoryIfc);
	SdpMemoryIfc#(Bit#(5), MotifSymbolGroup) memory <-
		mkSdpMemory(valueOf(MotifGroupDepth));

	method Action readGroup(Bit#(5) address);
		memory.readRequest(address);
	endmethod

	method MotifSymbolGroup readResponse;
		return memory.readResponse;
	endmethod

	method Action writeGroup(Bit#(5) address, MotifSymbolGroup value);
		memory.write(address, value);
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Packed 5-bit sequence storage with two-bank adjacent-row reads
//------------------------------------------------------------------------------------
typedef struct {
	Bit#(4) beatIdx;
	Bit#(512) word;
} SequenceLoadRequest deriving (Bits, Eq, FShow);

typedef struct {
	Bool firstRowEven;
	Bit#(4) startIndex;
} SequenceWindowMeta deriving (Bits, Eq, FShow);

interface SequenceMemoryIfc;
	method Action loadBeat(Bit#(4) beatIdx, Bit#(512) word);
	method Bool loadIdle;
	method Action readWindow(Bit#(11) startPosition);
	method ActionValue#(SequenceWindow) getWindow;
endinterface

module mkSequenceMemory(SequenceMemoryIfc);
	SdpMemoryIfc#(Bit#(5), SequenceRow) evenRowMemory <-
		mkSdpMemory(valueOf(SequenceBankDepth));
	SdpMemoryIfc#(Bit#(5), SequenceRow) oddRowMemory <-
		mkSdpMemory(valueOf(SequenceBankDepth));

	FIFOF#(SequenceLoadRequest) loadQ <- mkSizedFIFOF(2);
	FIFOF#(SequenceWindowMeta) windowMetaQ <- mkSizedFIFOF(2);
	Reg#(Bool) loadSecondOn <- mkReg(False);
	Reg#(SequenceLoadRequest) loadRequestR <- mkRegU;

	rule loadRows1 ( !loadSecondOn );
		SequenceLoadRequest request = loadQ.first;
		loadQ.deq;
		Bit#(5) pairAddress = {request.beatIdx, 1'b0};
		evenRowMemory.write(pairAddress, packSequenceRow(request.word, 0));
		oddRowMemory.write(pairAddress, packSequenceRow(request.word, 1));
		loadRequestR <= request;
		loadSecondOn <= True;
	endrule

	rule loadRows2 ( loadSecondOn );
		Bit#(5) pairAddress = {loadRequestR.beatIdx, 1'b0} + 1;
		evenRowMemory.write(pairAddress, packSequenceRow(loadRequestR.word, 2));
		oddRowMemory.write(pairAddress, packSequenceRow(loadRequestR.word, 3));
		loadSecondOn <= False;
	endrule

	method Action loadBeat(Bit#(4) beatIdx, Bit#(512) word);
		loadQ.enq(SequenceLoadRequest{
			beatIdx: beatIdx,
			word: word
			});
	endmethod

	method Bool loadIdle;
		return !loadQ.notEmpty && !loadSecondOn;
	endmethod

	method Action readWindow(Bit#(11) startPosition)
		if ( !loadQ.notEmpty && !loadSecondOn );
		Bit#(6) rowAddress = truncate(startPosition >> 4);
		Bit#(5) pairAddress = truncate(rowAddress >> 1);
		Bit#(4) startIndex = truncate(startPosition);
		Bool firstRowEven = rowAddress[0] == 0;

		if ( firstRowEven ) begin
			evenRowMemory.readRequest(pairAddress);
			oddRowMemory.readRequest(pairAddress);
		end else begin
			oddRowMemory.readRequest(pairAddress);
			if ( rowAddress == fromInteger(valueOf(SequenceRowNum) - 1) ) begin
				evenRowMemory.readRequest(0);
			end else begin
				evenRowMemory.readRequest(pairAddress + 1);
			end
		end
		windowMetaQ.enq(SequenceWindowMeta{
			firstRowEven: firstRowEven,
			startIndex: startIndex
			});
	endmethod

	method ActionValue#(SequenceWindow) getWindow;
		SequenceWindowMeta meta = windowMetaQ.first;
		windowMetaQ.deq;
		SequenceRow evenRow = evenRowMemory.readResponse;
		SequenceRow oddRow = oddRowMemory.readResponse;
		SequenceRow firstRow = meta.firstRowEven ? evenRow : oddRow;
		SequenceRow secondRow = meta.firstRowEven ? oddRow : evenRow;
		return selectSequenceWindow(firstRow, secondRow, meta.startIndex);
	endmethod
endmodule

endpackage
