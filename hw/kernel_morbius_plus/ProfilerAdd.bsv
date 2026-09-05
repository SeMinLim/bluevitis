package ProfilerAdd;

import MorbiusTypes::*;

// Two independent 24-bit additions. No pipeline or feedback latency is added.
interface ProfilerAddIfc;
	method Bit#(48) add(LogProb a0, LogProb a1, LogProb b0, LogProb b1);
endinterface

`ifdef MORBIUS_BLUESIM
module mkProfilerAdd(ProfilerAddIfc);
	method Bit#(48) add(LogProb a0, LogProb a1, LogProb b0, LogProb b1);
		LogProb sum0 = a0 + b0;
		LogProb sum1 = a1 + b1;
		return {pack(sum1), pack(sum0)};
	endmethod
endmodule
`else
import "BVI" MorbiusProfilerAdd =
module mkProfilerAdd(ProfilerAddIfc);
	default_clock clock(CLK);
	default_reset no_reset;
	method RESULT add(A0, A1, B0, B1);
	path (A0, RESULT);
	path (A1, RESULT);
	path (B0, RESULT);
	path (B1, RESULT);
	schedule add C add;
endmodule
`endif

endpackage
