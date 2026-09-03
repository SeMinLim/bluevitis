module MorbiusSdpRam #(
	parameter ADDR_WIDTH = 1,
	parameter DATA_WIDTH = 1,
	parameter MEMORY_SIZE = 2
) (
	input wire CLK,
	input wire REN,
	input wire [ADDR_WIDTH-1:0] RADDR,
	output wire [DATA_WIDTH-1:0] RDATA,
	input wire WE,
	input wire [ADDR_WIDTH-1:0] WADDR,
	input wire [DATA_WIDTH-1:0] WDATA
);

	(* ram_style = "block" *) reg [DATA_WIDTH-1:0] memory [0:MEMORY_SIZE-1];
	reg [DATA_WIDTH-1:0] readData;

	always @(posedge CLK) begin
		if ( REN ) begin
			readData <= memory[RADDR];
		end
	end

	always @(posedge CLK) begin
		if ( WE ) begin
			memory[WADDR] <= WDATA;
		end
	end

	assign RDATA = readData;

endmodule
