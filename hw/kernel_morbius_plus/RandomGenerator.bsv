package RandomGenerator;


typedef struct {
	Bit#(32) state0;
	Bit#(32) state1;
	Bit#(32) state2;
	Bit#(32) state3;
} RandomState deriving (Bits, Eq, FShow);

function Bit#(32) rotateLeft32(Bit#(32) value, Integer shift);
	return (value << shift) | (value >> (32 - shift));
endfunction

function RandomState initializeRandomState(Bit#(128) seedValue);
	Bit#(128) adjustedSeed = seedValue;
	if ( seedValue == 0 ) adjustedSeed = 1;
	return RandomState{
		state0: adjustedSeed[31:0],
		state1: adjustedSeed[63:32],
		state2: adjustedSeed[95:64],
		state3: adjustedSeed[127:96]
		};
endfunction

function Tuple2#(Bit#(32), RandomState) nextRandom(RandomState state);
	Bit#(32) result = state.state0 + state.state3;
	Bit#(32) shiftValue = state.state1 << 9;
	Bit#(32) next2 = state.state2 ^ state.state0;
	Bit#(32) next3 = state.state3 ^ state.state1;
	Bit#(32) next1 = state.state1 ^ next2;
	Bit#(32) next0 = state.state0 ^ next3;
	next2 = next2 ^ shiftValue;
	next3 = rotateLeft32(next3, 11);
	return tuple2(result,
		      RandomState{
			state0: next0,
			state1: next1,
			state2: next2,
			state3: next3
			});
endfunction

endpackage
