package PwlLane;

import FIFO::*;
import FIFOF::*;

import MorbiusTypes::*;


interface PwlLaneIfc;
	method Action put(PwlRequest request);
	method ActionValue#(PwlResponse) get;
endinterface

function UInt#(19) logBase(Bit#(4) idx);
	case ( idx )
		0:  return 0;
		1:  return 22928;
		2:  return 44545;
		3:  return 64993;
		4:  return 84392;
		5:  return 102844;
		6:  return 120437;
		7:  return 137249;
		8:  return 153344;
		9:  return 168783;
		10: return 183616;
		11: return 197889;
		12: return 211643;
		13: return 224915;
		14: return 237736;
		default: return 250137;
	endcase
endfunction

function UInt#(19) logDelta(Bit#(4) idx);
	case ( idx )
		0:  return 22928;
		1:  return 21617;
		2:  return 20448;
		3:  return 19399;
		4:  return 18452;
		5:  return 17594;
		6:  return 16811;
		7:  return 16096;
		8:  return 15439;
		9:  return 14833;
		10: return 14273;
		11: return 13754;
		12: return 13271;
		13: return 12821;
		14: return 12401;
		default: return 12007;
	endcase
endfunction

function UInt#(19) expBase(Bit#(4) idx);
	case ( idx )
		0:  return 262144;
		1:  return 251030;
		2:  return 240387;
		3:  return 230195;
		4:  return 220436;
		5:  return 211090;
		6:  return 202141;
		7:  return 193571;
		8:  return 185364;
		9:  return 177505;
		10: return 169979;
		11: return 162773;
		12: return 155872;
		13: return 149263;
		14: return 142935;
		default: return 136875;
	endcase
endfunction

function UInt#(19) expDelta(Bit#(4) idx);
	case ( idx )
		0:  return 11114;
		1:  return 10643;
		2:  return 10192;
		3:  return 9760;
		4:  return 9346;
		5:  return 8950;
		6:  return 8570;
		7:  return 8207;
		8:  return 7859;
		9:  return 7526;
		10: return 7207;
		11: return 6901;
		12: return 6608;
		13: return 6328;
		14: return 6060;
		default: return 5803;
	endcase
endfunction

function UInt#(19) interpolate(UInt#(19) base,
				      UInt#(19) delta,
				      Bit#(8) residual,
				      Bool subtractCorrection);
	UInt#(27) product = zeroExtend(delta) * zeroExtend(unpack(residual));
	UInt#(20) correction = truncate((product + 128) >> 8);
	if ( subtractCorrection ) return base - truncate(correction);
	else return base + truncate(correction);
endfunction

function UInt#(5) leadingOne(UInt#(18) count);
	UInt#(5) result = 0;
	if ( count >= 131072 ) result = 17;
	else if ( count >= 65536 ) result = 16;
	else if ( count >= 32768 ) result = 15;
	else if ( count >= 16384 ) result = 14;
	else if ( count >= 8192 ) result = 13;
	else if ( count >= 4096 ) result = 12;
	else if ( count >= 2048 ) result = 11;
	else if ( count >= 1024 ) result = 10;
	else if ( count >= 512 ) result = 9;
	else if ( count >= 256 ) result = 8;
	else if ( count >= 128 ) result = 7;
	else if ( count >= 64 ) result = 6;
	else if ( count >= 32 ) result = 5;
	else if ( count >= 16 ) result = 4;
	else if ( count >= 8 ) result = 3;
	else if ( count >= 4 ) result = 2;
	else if ( count >= 2 ) result = 1;
	return result;
endfunction

function PwlValue calculateLog2(UInt#(32) inputValue);
	UInt#(18) count = truncate(inputValue);
	UInt#(5) integerPart = leadingOne(count);
	UInt#(18) leadingValue = 1 << integerPart;
	UInt#(30) numerator = zeroExtend(count - leadingValue) << 12;
	UInt#(12) fractionCode = truncate(numerator >> integerPart);
	Bit#(12) fractionBits = pack(fractionCode);
	Bit#(4) interval = truncate(fractionBits >> 8);
	Bit#(8) residual = truncate(fractionBits);
	UInt#(19) fractionQ18 = interpolate(logBase(interval),
						   logDelta(interval),
						   residual,
						   False);
	UInt#(13) fractionQ12 = truncate((fractionQ18 + 32) >> 6);
	UInt#(6) adjustedInteger = zeroExtend(integerPart);
	UInt#(12) adjustedFraction = truncate(fractionQ12);
	if ( fractionQ12 >= 4096 ) begin
		adjustedInteger = adjustedInteger + 1;
		adjustedFraction = truncate(fractionQ12 - 4096);
	end
	UInt#(19) combinedValue = (zeroExtend(adjustedInteger) << 12) | zeroExtend(adjustedFraction);
	return combinedValue;
endfunction

function PwlValue calculateExp2(UInt#(32) differenceQ12);
	UInt#(20) integerPart = truncate(differenceQ12 >> 12);
	Bit#(32) differenceBits = pack(differenceQ12);
	Bit#(12) fractionCode = truncate(differenceBits);
	Bit#(4) interval = truncate(fractionCode >> 8);
	Bit#(8) residual = truncate(fractionCode);
	UInt#(19) fractionQ18 = interpolate(expBase(interval),
						   expDelta(interval),
						   residual,
						   True);
	if ( integerPart > 18 ) return 0;
	else return fractionQ18 >> integerPart;
endfunction

module mkPwlLane(PwlLaneIfc);
	FIFOF#(PwlRequest) requestQ <- mkFIFOF;
	FIFOF#(PwlResponse) responseQ <- mkFIFOF;

	rule process1;
		PwlRequest request = requestQ.first;
		requestQ.deq;
		PwlValue value = 0;
		if ( request.mode == PWL_LOG2 ) value = calculateLog2(request.value);
		else value = calculateExp2(request.value);
		responseQ.enq(PwlResponse{
			mode: request.mode,
			value: value,
			tag: request.tag
			});
	endrule

	method Action put(PwlRequest request);
		requestQ.enq(request);
	endmethod

	method ActionValue#(PwlResponse) get;
		PwlResponse response = responseQ.first;
		responseQ.deq;
		return response;
	endmethod
endmodule

endpackage
