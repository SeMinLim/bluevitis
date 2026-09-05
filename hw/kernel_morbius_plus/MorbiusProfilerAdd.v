module MorbiusProfilerAdd (
	input wire CLK,
	input wire [23:0] A0,
	input wire [23:0] A1,
	input wire [23:0] B0,
	input wire [23:0] B1,
	output wire [47:0] RESULT
);
	wire [47:0] x = {A1, A0};
	wire [47:0] c = {B1, B0};

	// TWO24 blocks carry propagation across bit 23. The BSV accumulator
	// registers retain state, preserving the original one-cycle feedback path.
	DSP48E2 #(
		.AREG(0), .ACASCREG(0), .BREG(0), .BCASCREG(0),
		.CREG(0), .DREG(0), .ADREG(0), .MREG(0), .PREG(0),
		.INMODEREG(0), .OPMODEREG(0), .ALUMODEREG(0),
		.CARRYINREG(0), .CARRYINSELREG(0),
		.USE_MULT("NONE"), .USE_SIMD("TWO24")
	) arithmetic (
		.CLK(CLK), .A(x[47:18]), .B(x[17:0]), .C(c), .D(27'd0),
		.ACIN(30'd0), .BCIN(18'd0), .PCIN(48'd0),
		.ALUMODE(4'b0000), .INMODE(5'b00000),
		.OPMODE(9'b000110011), // W=0, Z=C, Y=0, X=A:B
		.CARRYIN(1'b0), .CARRYINSEL(3'b000),
		.CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0),
		.CEA1(1'b0), .CEA2(1'b0), .CEB1(1'b0), .CEB2(1'b0),
		.CEC(1'b0), .CED(1'b0), .CEAD(1'b0), .CEM(1'b0), .CEP(1'b0),
		.CEALUMODE(1'b0), .CECTRL(1'b0), .CEINMODE(1'b0), .CECARRYIN(1'b0),
		.RSTA(1'b0), .RSTB(1'b0), .RSTC(1'b0), .RSTD(1'b0),
		.RSTINMODE(1'b0), .RSTALUMODE(1'b0), .RSTCTRL(1'b0),
		.RSTM(1'b0), .RSTP(1'b0), .RSTALLCARRYIN(1'b0),
		.P(RESULT)
	);
endmodule
