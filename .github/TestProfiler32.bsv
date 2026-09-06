package TestProfiler32;

import Vector::*;
import MorbiusTypes::*;
import GibbsPipeline::*;

(* synthesize *)
module mkTestProfiler32(Empty);
	Reg#(UInt#(16)) caseCnt <- mkReg(0);
	Reg#(Bit#(32)) randomR <- mkReg(32'h6a09e667);

	rule check1;
		Bit#(5) lowCase = truncate(pack(caseCnt));
		Bit#(ProfilerValidWidth) validNum = zeroExtend(lowCase) + 1;
		if ( caseCnt >= 32 && caseCnt < 64 ) validNum = 32;
		Vector#(NumPE_Profiler, WeightValue) weight = replicate(0);
		Vector#(NumPE_Profiler, LogProb) logProb = replicate(0);
		UInt#(32) expectedMass = 0;
		LogProb expectedMaximum = 0;
		Bit#(32) randomValue = randomR;

		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			randomValue = randomValue ^ (randomValue << 13);
			randomValue = randomValue ^ (randomValue >> 17);
			randomValue = randomValue ^ (randomValue << 5);
			UInt#(18) smallWeight = unpack(randomValue[17:0]);
			WeightValue value = zeroExtend(smallWeight);
			if ( caseCnt < 32 ) value = 262144;
			else if ( caseCnt < 64 ) value = fromInteger(i) == lowCase ? 262144 : 0;
			if ( fromInteger(i) < validNum ) begin
				weight[i] = value;
				expectedMass = expectedMass + zeroExtend(value);
			end
			// Invalid entries deliberately exceed every valid entry.
			LogProb entry = fromInteger(i * 4096 + 17);
			logProb[i] = fromInteger(i) < validNum ? entry : 16777215;
			if ( fromInteger(i) < validNum && entry > expectedMaximum ) expectedMaximum = entry;
		end

		Bit#(24) randomFraction = randomValue[31:8];
		if ( lowCase[0] == 0 ) randomFraction = 0;
		else if ( lowCase[1] == 0 || caseCnt == 31 ) randomFraction = '1;
		UInt#(64) massWide = zeroExtend(expectedMass);
		UInt#(64) randomWide = zeroExtend(unpack(randomFraction));
		UInt#(64) product = massWide * randomWide;
		UInt#(32) threshold = truncate(product >> 24);
		UInt#(32) cumulative = 0;
		Bit#(ProfilerOffsetWidth) expectedOffset = truncate(validNum - 1);
		Bool found = False;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			cumulative = cumulative + zeroExtend(weight[i]);
			if ( !found && fromInteger(i) < validNum && cumulative > threshold ) begin
				expectedOffset = fromInteger(i);
				found = True;
			end
		end

		WeightTree tree = buildWeightTree(weight);
		let actualOffset = selectLocalCandidate(weight, tree, randomFraction, validNum);
		LogProb actualMaximum = maxLogProbSegment(logProb, validNum);
		if ( zeroExtend(tree.total) != expectedMass || actualOffset != expectedOffset ||
		     actualMaximum != expectedMaximum ) begin
			$display("FAIL: 32-lane tree case=%0d valid=%0d mass=%0d expected=%0d offset=%0d expected=%0d max=%0d expected=%0d",
				caseCnt, validNum, tree.total, expectedMass, actualOffset, expectedOffset,
				actualMaximum, expectedMaximum);
			$finish(1);
		end
		if ( caseCnt == 31 && (tree.total != 8388608 || actualOffset != 31) ) begin
			$display("FAIL: full 32-candidate maximum-mass endpoint");
			$finish(1);
		end
		if ( caseCnt == 2111 ) begin
			$display("PASS: 2112 cases, 32-way maximum/sum/selection, all valid counts, upper lanes and maximum mass");
			$finish(0);
		end
		caseCnt <= caseCnt + 1;
		randomR <= randomValue;
	endrule
endmodule

endpackage
