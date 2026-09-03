package SdpMemory;

`ifdef MORBIUS_BLUESIM
import RegFile::*;
`endif


interface SdpMemoryIfc#(type addressType, type dataType);
	method Action readRequest(addressType address);
	method dataType readResponse;
	method Action write(addressType address, dataType value);
endinterface


`ifdef MORBIUS_BLUESIM
module mkSdpMemory#(Integer memorySize)
	(SdpMemoryIfc#(addressType, dataType))
	provisos(
		Bits#(addressType, addressWidth),
		Bits#(dataType, dataWidth),
		Bounded#(addressType)
	);
	RegFile#(addressType, dataType) memory <- mkRegFile(minBound, maxBound);
	Reg#(addressType) readAddressR <- mkReg(minBound);

	method Action readRequest(addressType address);
		readAddressR <= address;
	endmethod

	method dataType readResponse;
		return memory.sub(readAddressR);
	endmethod

	method Action write(addressType address, dataType value);
		memory.upd(address, value);
	endmethod
endmodule
`else
import "BVI" MorbiusSdpRam =
module mkSdpMemory#(Integer memorySize)
	(SdpMemoryIfc#(addressType, dataType))
	provisos(
		Bits#(addressType, addressWidth),
		Bits#(dataType, dataWidth),
		Bounded#(addressType)
	);

	default_clock clock(CLK);
	default_reset no_reset;

	parameter ADDR_WIDTH = valueOf(addressWidth);
	parameter DATA_WIDTH = valueOf(dataWidth);
	parameter MEMORY_SIZE = memorySize;

	method readRequest(RADDR) enable(REN);
	method RDATA readResponse();
	method write(WADDR, WDATA) enable(WE);

	schedule readResponse CF (readResponse, readRequest, write);
	schedule readRequest CF write;
	schedule readRequest C readRequest;
	schedule write C write;
endmodule
`endif


endpackage
