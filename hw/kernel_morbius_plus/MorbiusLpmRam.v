module MorbiusLpmRam (
	input wire CLK,
	input wire REN,
	input wire [6:0] RADDR,
	output wire [339:0] RDATA,
	input wire WEN,
	input wire [4:0] WADDR,
	input wire [1439:0] WDATA,
	input wire [79:0] WMASK
);
	genvar s;
	generate
		for ( s = 0; s < 20; s = s + 1 ) begin: symbolBank
			wire [71:0] word = WDATA[s * 72 +: 72];
			wire [3:0] mask = WMASK[s * 4 +: 4];
			wire [63:0] dataBits = {word[69:54], word[51:36], word[33:18], word[15:0]};
			wire [7:0] parityBits = {word[71:70], word[53:52], word[35:34], word[17:16]};
			wire [7:0] byteEnable = {{2{mask[3]}}, {2{mask[2]}}, {2{mask[1]}}, {2{mask[0]}}};
			wire [31:0] readData;
			wire [3:0] readParity;

			// One RAMB36 per symbol. 72-bit writes contain four 18-bit slots;
			// 18-bit reads select one column without a fabric four-way mux.
			RAMB36E2 #(
				.READ_WIDTH_A(18), .READ_WIDTH_B(0),
				.WRITE_WIDTH_A(0), .WRITE_WIDTH_B(72),
				.DOA_REG(0), .DOB_REG(0),
				.CLOCK_DOMAINS("COMMON"),
				.WRITE_MODE_A("READ_FIRST"), .WRITE_MODE_B("READ_FIRST"),
				.EN_ECC_READ("FALSE"), .EN_ECC_WRITE("FALSE")
			) memory (
				.CLKARDCLK(CLK), .CLKBWRCLK(CLK),
				.ADDRARDADDR({4'd0, RADDR, 4'd0}),
				.ADDRBWRADDR({4'd0, WADDR, 6'd0}),
				.ADDRENA(1'b1), .ADDRENB(1'b1),
				.ENARDEN(REN), .ENBWREN(WEN && (|mask)),
				.WEA(4'd0), .WEBWE(byteEnable),
				.DINADIN(dataBits[31:0]), .DINBDIN(dataBits[63:32]),
				.DINPADINP(parityBits[3:0]), .DINPBDINP(parityBits[7:4]),
				.DOUTADOUT(readData), .DOUTPADOUTP(readParity),
				.REGCEAREGCE(1'b0), .REGCEB(1'b0),
				.RSTRAMARSTRAM(1'b0), .RSTRAMB(1'b0),
				.RSTREGARSTREG(1'b0), .RSTREGB(1'b0),
				.SLEEP(1'b0), .ECCPIPECE(1'b0),
				.INJECTDBITERR(1'b0), .INJECTSBITERR(1'b0),
				.CASDINA(32'd0), .CASDINB(32'd0),
				.CASDINPA(4'd0), .CASDINPB(4'd0),
				.CASDIMUXA(1'b0), .CASDIMUXB(1'b0),
				.CASDOMUXA(1'b0), .CASDOMUXB(1'b0),
				.CASDOMUXEN_A(1'b0), .CASDOMUXEN_B(1'b0),
				.CASOREGIMUXA(1'b0), .CASOREGIMUXB(1'b0),
				.CASOREGIMUXEN_A(1'b0), .CASOREGIMUXEN_B(1'b0),
				.CASINDBITERR(1'b0), .CASINSBITERR(1'b0)
			);
			assign RDATA[s * 17 +: 17] = {readParity[0], readData[15:0]};
		end
	endgenerate
endmodule
