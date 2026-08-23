package RandomGenerator;

import FIFOF::*;


interface RandomGeneratorIfc;
	method Action seed(Bit#(128) seedValue);
	method Action start;
	method ActionValue#(Bit#(32)) get;
endinterface

function Bit#(32) rotateLeft32(Bit#(32) value, Integer shift);
	return (value << shift) | (value >> (32 - shift));
endfunction

module mkRandomGenerator(RandomGeneratorIfc);
	Reg#(Bit#(32)) state0 <- mkReg(0);
	Reg#(Bit#(32)) state1 <- mkReg(0);
	Reg#(Bit#(32)) state2 <- mkReg(0);
	Reg#(Bit#(32)) state3 <- mkReg(0);
	Reg#(Bool) seeded <- mkReg(False);
	Reg#(Bool) generateOn <- mkReg(False);
	FIFOF#(Bit#(32)) randomQ <- mkSizedFIFOF(8);

	rule generateRandom ( seeded && generateOn && randomQ.notFull );
		Bit#(32) result = state0 + state3;
		Bit#(32) shiftValue = state1 << 9;
		Bit#(32) next2 = state2 ^ state0;
		Bit#(32) next3 = state3 ^ state1;
		Bit#(32) next1 = state1 ^ next2;
		Bit#(32) next0 = state0 ^ next3;
		next2 = next2 ^ shiftValue;
		next3 = rotateLeft32(next3, 11);

		state0 <= next0;
		state1 <= next1;
		state2 <= next2;
		state3 <= next3;
		randomQ.enq(result);
	endrule

	method Action seed(Bit#(128) seedValue) if ( !seeded );
		Bit#(128) adjustedSeed = seedValue;
		if ( seedValue == 0 ) adjustedSeed = 1;
		state0 <= adjustedSeed[31:0];
		state1 <= adjustedSeed[63:32];
		state2 <= adjustedSeed[95:64];
		state3 <= adjustedSeed[127:96];
		seeded <= True;
	endmethod

	method Action start if ( seeded && !generateOn );
		generateOn <= True;
	endmethod

	method ActionValue#(Bit#(32)) get;
		Bit#(32) value = randomQ.first;
		randomQ.deq;
		return value;
	endmethod
endmodule

endpackage
