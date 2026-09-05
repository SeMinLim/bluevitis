`timescale 1ns/1ps
// Test-only cycle contracts. TestResourcePrimitives compares these models with
// the real Xilinx UNISIM instances before they are used for long RTL traces.
// These modules are not included in kernel packaging.
module MorbiusProfilerAddModel (
	input wire CLK,
	input wire [23:0] A0,
	input wire [23:0] A1,
	input wire [23:0] B0,
	input wire [23:0] B1,
	output wire [47:0] RESULT
);
	wire [23:0] sum0 = A0 + B0;
	wire [23:0] sum1 = A1 + B1;
	assign RESULT = {sum1, sum0};
endmodule

module MorbiusLpmRamModel (
	input wire CLK,
	input wire REN,
	input wire [6:0] RADDR,
	output reg [339:0] RDATA,
	input wire WEN,
	input wire [4:0] WADDR,
	input wire [1439:0] WDATA,
	input wire [79:0] WMASK
);
	reg [16:0] memory [0:19][0:127];
	integer symbol, column;
	always @(posedge CLK) begin
		if ( REN ) begin
			for ( symbol = 0; symbol < 20; symbol = symbol + 1 ) begin
				RDATA[symbol * 17 +: 17] <= memory[symbol][RADDR];
			end
		end
		if ( WEN ) begin
			for ( symbol = 0; symbol < 20; symbol = symbol + 1 ) begin
				for ( column = 0; column < 4; column = column + 1 ) begin
					if ( WMASK[symbol * 4 + column] ) begin
						memory[symbol][WADDR * 4 + column] <=
							WDATA[(symbol * 4 + column) * 18 +: 17];
					end
				end
			end
		end
	end
endmodule
