`timescale 1ns/1ps
module TestResourcePrimitives;
	reg clk = 0;
	always #5 clk = ~clk;
	reg [23:0] a0 = 0, a1 = 0, b0 = 0, b1 = 0;
	wire [47:0] sums;
	wire [47:0] modelSums;
	wire [339:0] modelData;
	reg [23:0] expected0, expected1;
	reg ren = 0, wen = 0;
	reg [6:0] raddr = 0;
	reg [4:0] waddr = 0;
	// Drive every data bit before the first valid write. Starting inactive data
	// unknown also exercises the native model's input-buffer initialization.
	reg [1439:0] wdata;
	reg [79:0] wmask = 0;
	wire [339:0] rdata;
	reg [16:0] reference [0:19][0:127];
	reg [339:0] held;
	integer i, s, c, g;
	integer randomSeed = 1729;
	reg [31:0] randomValue;

	MorbiusProfilerAdd add(clk, a0, a1, b0, b1, sums);
	MorbiusLpmRam memory(clk, ren, raddr, rdata, wen, waddr, wdata, wmask);
	MorbiusProfilerAddModel addModel(clk, a0, a1, b0, b1, modelSums);
	MorbiusLpmRamModel memoryModel(clk, ren, raddr, modelData, wen, waddr, wdata, wmask);

	task checkColumn;
		input integer column;
		begin
			for ( integer symbol = 0; symbol < 20; symbol = symbol + 1 ) begin
				if ( rdata[symbol * 17 +: 17] !== reference[symbol][column] ||
				     modelData[symbol * 17 +: 17] !== reference[symbol][column] ) begin
					$fatal(1, "FAIL LPM column=%0d symbol=%0d expected=%h got=%h",
						column, symbol, reference[symbol][column], rdata[symbol * 17 +: 17]);
				end
			end
		end
	endtask

	initial begin
		#200;
		for ( i = 0; i < 10000; i = i + 1 ) begin
			a0 = $random(randomSeed); a1 = $random(randomSeed);
			b0 = $random(randomSeed); b1 = $random(randomSeed);
			if ( i == 0 ) begin a0 = 24'hffffff; b0 = 1; a1 = 0; b1 = 0; end
			if ( i == 1 ) begin a1 = 24'hffffff; b1 = 1; a0 = 0; b0 = 0; end
			expected0 = a0 + b0;
			expected1 = a1 + b1;
			#1;
			if ( sums !== {expected1, expected0} || sums !== modelSums ) begin
				$fatal(1, "FAIL DSP SIMD expected=%h got=%h", {expected1, expected0}, sums);
			end
		end
		$display("PASS: 10000 native DSP TWO24 cases, including cross-lane carry isolation");

		for ( g = 0; g < 32; g = g + 1 ) begin
			@(negedge clk);
			wen = 1; waddr = g; wmask = '1; ren = 0;
			for ( s = 0; s < 20; s = s + 1 ) begin
				for ( c = 0; c < 4; c = c + 1 ) begin
					randomValue = $random(randomSeed);
					reference[s][g * 4 + c] = randomValue[16:0];
					wdata[(s * 4 + c) * 18 +: 18] = {1'b0, randomValue[16:0]};
				end
			end
			@(posedge clk); #1;
		end
		@(negedge clk); wen = 0;
		for ( i = 0; i < 128; i = i + 1 ) begin
			@(negedge clk); ren = 1; raddr = i;
			@(posedge clk); #1; checkColumn(i);
		end
		for ( i = 0; i < 1024; i = i + 1 ) begin
			g = i % 32;
			@(negedge clk); wen = 1; ren = 0; waddr = g;
			for ( s = 0; s < 20; s = s + 1 ) begin
				for ( c = 0; c < 4; c = c + 1 ) begin
					randomValue = $random(randomSeed);
					wmask[s * 4 + c] = randomValue[31];
					wdata[(s * 4 + c) * 18 +: 18] = {1'b0, randomValue[16:0]};
					if ( randomValue[31] ) reference[s][g * 4 + c] = randomValue[16:0];
				end
			end
			@(posedge clk); #1;
			for ( c = 0; c < 4; c = c + 1 ) begin
				@(negedge clk); wen = 0; ren = 1; raddr = g * 4 + c;
				@(posedge clk); #1; checkColumn(g * 4 + c);
			end
		end
		@(negedge clk); ren = 0; held = rdata;
		repeat ( 4 ) begin
			@(posedge clk); #1;
			if ( rdata !== held || modelData !== held ) $fatal(1, "FAIL LPM read hold");
		end
		$display("PASS: all LPM addresses and 1024 native masked group updates");
		$finish;
	end
endmodule
