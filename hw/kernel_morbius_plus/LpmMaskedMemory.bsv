package LpmMaskedMemory;

import Vector::*;
`ifdef MORBIUS_BLUESIM
import RegFile::*;
`endif

import MorbiusTypes::*;

interface LpmRamIfc;
	method Action readColumn(Bit#(7) address);
	method Bit#(340) readResponse;
	method Action write(Bit#(5) address, Bit#(1440) value, Bit#(80) mask);
endinterface

`ifdef MORBIUS_BLUESIM
module mkLpmRam(LpmRamIfc);
	Vector#(20, Vector#(4, RegFile#(Bit#(5), Bit#(18)))) memory <-
		replicateM(replicateM(mkRegFileFull));
	Reg#(Bit#(7)) readAddressR <- mkReg(0);

	method Action readColumn(Bit#(7) address);
		readAddressR <= address;
	endmethod

	method Bit#(340) readResponse;
		Bit#(340) value = 0;
		Bit#(5) groupAddress = readAddressR[6:2];
		Bit#(2) columnOffset = readAddressR[1:0];
		for ( Integer s = 0; s < 20; s = s + 1 ) begin
			Vector#(4, Bit#(18)) columns = newVector;
			for ( Integer c = 0; c < 4; c = c + 1 ) begin
				columns[c] = memory[s][c].sub(groupAddress);
			end
			Bit#(18) entry = columns[columnOffset];
			value[s * 17 + 16:s * 17] = entry[16:0];
		end
		return value;
	endmethod

	method Action write(Bit#(5) address, Bit#(1440) value, Bit#(80) mask);
		for ( Integer s = 0; s < 20; s = s + 1 ) begin
			for ( Integer c = 0; c < 4; c = c + 1 ) begin
				Integer slot = s * 4 + c;
				if ( mask[slot] == 1 ) begin
					memory[s][c].upd(address, value[slot * 18 + 17:slot * 18]);
				end
			end
		end
	endmethod
endmodule
`else
import "BVI" MorbiusLpmRam =
module mkLpmRam(LpmRamIfc);
	default_clock clock(CLK);
	default_reset no_reset;
	method readColumn(RADDR) enable(REN);
	method RDATA readResponse();
	method write(WADDR, WDATA, WMASK) enable(WEN);
	schedule readResponse CF (readResponse, readColumn, write);
	schedule readColumn CF write;
	schedule readColumn C readColumn;
	schedule write C write;
endmodule
`endif

// Independent symbol banks: four-column masked writes, one-column reads.
interface LpmMemoryIfc;
	method Action loadGroup(Bit#(5) address, LpmGroup value);
	method Action readColumn(Bit#(7) address);
	method LpmEntries readResponse;
	method Action writeChanged(Bit#(5) address,
				   MotifSymbolGroup previousSymbol,
				   MotifSymbolGroup currentSymbol,
				   Vector#(NumPE_LPM, LogValue) previousValue,
				   Vector#(NumPE_LPM, LogValue) currentValue,
				   Bit#(NumPE_LPM) changedMask);
endinterface

module mkLpmMemory(LpmMemoryIfc);
	LpmRamIfc memory <- mkLpmRam;

	method Action loadGroup(Bit#(5) address, LpmGroup value);
		Bit#(1440) encoded = 0;
		for ( Integer s = 0; s < valueOf(AlphabetMax); s = s + 1 ) begin
			for ( Integer c = 0; c < valueOf(NumPE_LPM); c = c + 1 ) begin
				Integer low = (s * 4 + c) * 18;
				Bit#(18) entry = zeroExtend(pack(value[c][s]));
				encoded[low + 17:low] = entry;
			end
		end
		memory.write(address, encoded, '1);
	endmethod

	method Action readColumn(Bit#(7) address);
		memory.readColumn(address);
	endmethod

	method LpmEntries readResponse;
		Bit#(340) encoded = memory.readResponse;
		LpmEntries value = newVector;
		for ( Integer s = 0; s < valueOf(AlphabetMax); s = s + 1 ) begin
			value[s] = unpack(encoded[s * 17 + 16:s * 17]);
		end
		return value;
	endmethod

	method Action writeChanged(Bit#(5) address,
				   MotifSymbolGroup previousSymbol,
				   MotifSymbolGroup currentSymbol,
				   Vector#(NumPE_LPM, LogValue) previousValue,
				   Vector#(NumPE_LPM, LogValue) currentValue,
				   Bit#(NumPE_LPM) changedMask);
		Bit#(1440) encoded = 0;
		Bit#(80) mask = 0;
		for ( Integer s = 0; s < valueOf(AlphabetMax); s = s + 1 ) begin
			for ( Integer c = 0; c < valueOf(NumPE_LPM); c = c + 1 ) begin
				Integer slot = s * 4 + c;
				LogValue entry = 0;
				Bool selected = False;
				if ( changedMask[c] == 1 ) begin
					if ( previousSymbol[c] == fromInteger(s) ) begin
						entry = previousValue[c];
						selected = True;
					end
					if ( currentSymbol[c] == fromInteger(s) ) begin
						entry = currentValue[c];
						selected = True;
					end
				end
				Bit#(18) entryBits = zeroExtend(pack(entry));
				encoded[slot * 18 + 17:slot * 18] = entryBits;
				mask[slot] = pack(selected);
			end
		end
		memory.write(address, encoded, mask);
	endmethod
endmodule

endpackage
