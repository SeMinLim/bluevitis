package PwlLane;

import FIFOF::*;
import Vector::*;

import MorbiusTypes::*;


interface PwlArrayIfc;
	method Action put(PwlArrayRequest request);
	method ActionValue#(PwlArrayResponse) get;
endinterface


typedef struct {
	Bool valid;
	UInt#(5) integerPart;
	Bool underflow;
	UInt#(19) base;
	UInt#(19) delta;
	Bit#(8) residual;
} PwlLaneStage1 deriving (Bits, Eq, FShow);

typedef struct {
	PwlMode mode;
	Vector#(NumPE_Profiler, PwlLaneStage1) lane;
} PwlStage1 deriving (Bits, Eq, FShow);

typedef struct {
	Bool valid;
	UInt#(5) integerPart;
	Bool underflow;
	UInt#(19) base;
	UInt#(27) product;
} PwlLaneStage2 deriving (Bits, Eq, FShow);

typedef struct {
	PwlMode mode;
	Vector#(NumPE_Profiler, PwlLaneStage2) lane;
} PwlStage2 deriving (Bits, Eq, FShow);


function Tuple2#(UInt#(19), UInt#(19)) getLogCoefficient(Bit#(4) interval);
	case ( interval )
		0: return tuple2(0, 22928);
		1: return tuple2(22928, 21617);
		2: return tuple2(44545, 20448);
		3: return tuple2(64993, 19399);
		4: return tuple2(84392, 18452);
		5: return tuple2(102844, 17594);
		6: return tuple2(120437, 16811);
		7: return tuple2(137249, 16096);
		8: return tuple2(153344, 15439);
		9: return tuple2(168783, 14833);
		10: return tuple2(183616, 14273);
		11: return tuple2(197889, 13754);
		12: return tuple2(211643, 13271);
		13: return tuple2(224915, 12821);
		14: return tuple2(237736, 12401);
		default: return tuple2(250137, 12007);
	endcase
endfunction

function Tuple2#(UInt#(19), UInt#(19)) getExpCoefficient(Bit#(4) interval);
	case ( interval )
		0: return tuple2(262144, 11114);
		1: return tuple2(251030, 10643);
		2: return tuple2(240387, 10192);
		3: return tuple2(230195, 9760);
		4: return tuple2(220436, 9346);
		5: return tuple2(211090, 8950);
		6: return tuple2(202141, 8570);
		7: return tuple2(193571, 8207);
		8: return tuple2(185364, 7859);
		9: return tuple2(177505, 7526);
		10: return tuple2(169979, 7207);
		11: return tuple2(162773, 6901);
		12: return tuple2(155872, 6608);
		13: return tuple2(149263, 6328);
		14: return tuple2(142935, 6060);
		default: return tuple2(136875, 5803);
	endcase
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

function UInt#(18) leadingValue(UInt#(5) shift);
	case ( shift )
		0: return 1;
		1: return 2;
		2: return 4;
		3: return 8;
		4: return 16;
		5: return 32;
		6: return 64;
		7: return 128;
		8: return 256;
		9: return 512;
		10: return 1024;
		11: return 2048;
		12: return 4096;
		13: return 8192;
		14: return 16384;
		15: return 32768;
		16: return 65536;
		default: return 131072;
	endcase
endfunction

function UInt#(30) boundedShiftRight30(UInt#(30) value, UInt#(5) shift);
	case ( shift )
		0: return value;
		1: return value >> 1;
		2: return value >> 2;
		3: return value >> 3;
		4: return value >> 4;
		5: return value >> 5;
		6: return value >> 6;
		7: return value >> 7;
		8: return value >> 8;
		9: return value >> 9;
		10: return value >> 10;
		11: return value >> 11;
		12: return value >> 12;
		13: return value >> 13;
		14: return value >> 14;
		15: return value >> 15;
		16: return value >> 16;
		default: return value >> 17;
	endcase
endfunction

function WeightValue boundedShiftRight19(WeightValue value, UInt#(5) shift);
	case ( shift )
		0: return value;
		1: return value >> 1;
		2: return value >> 2;
		3: return value >> 3;
		4: return value >> 4;
		5: return value >> 5;
		6: return value >> 6;
		7: return value >> 7;
		8: return value >> 8;
		9: return value >> 9;
		10: return value >> 10;
		11: return value >> 11;
		12: return value >> 12;
		13: return value >> 13;
		14: return value >> 14;
		15: return value >> 15;
		16: return value >> 16;
		17: return value >> 17;
		18: return value >> 18;
		default: return 0;
	endcase
endfunction

function PwlLaneStage1 prepareDualModeLane(PwlMode mode,
					    PwlInput inputValue,
					    Bool valid);
	UInt#(5) integerPart = 0;
	Bool underflow = False;
	Bit#(4) interval = 0;
	Bit#(8) residual = 0;
	UInt#(19) base = 0;
	UInt#(19) delta = 0;

	if ( mode == PWL_LOG2 ) begin
		UInt#(18) count = truncate(inputValue);
		if ( count == 0 ) count = 1;
		integerPart = leadingOne(count);
		UInt#(18) lead = leadingValue(integerPart);
		UInt#(30) numerator = zeroExtend(count - lead) << 12;
		UInt#(12) fractionCode = truncate(boundedShiftRight30(numerator,
								integerPart));
		Bit#(12) fractionBits = pack(fractionCode);
		interval = fractionBits[11:8];
		residual = fractionBits[7:0];
		Tuple2#(UInt#(19), UInt#(19)) coefficient = getLogCoefficient(interval);
		base = tpl_1(coefficient);
		delta = tpl_2(coefficient);
	end else begin
		UInt#(12) expInteger = truncate(inputValue >> 12);
		underflow = expInteger > 18;
		integerPart = truncate(expInteger);
		Bit#(12) fractionCode = truncate(pack(inputValue));
		interval = fractionCode[11:8];
		residual = fractionCode[7:0];
		Tuple2#(UInt#(19), UInt#(19)) coefficient = getExpCoefficient(interval);
		base = tpl_1(coefficient);
		delta = tpl_2(coefficient);
	end

	return PwlLaneStage1{
		valid: valid,
		integerPart: integerPart,
		underflow: underflow,
		base: base,
		delta: delta,
		residual: residual
		};
endfunction

function PwlLaneStage1 prepareExpOnlyLane(PwlMode mode,
					   PwlInput inputValue,
					   Bool valid);
	UInt#(12) expInteger = truncate(inputValue >> 12);
	Bit#(12) fractionCode = truncate(pack(inputValue));
	Bit#(4) interval = fractionCode[11:8];
	Bit#(8) residual = fractionCode[7:0];
	Tuple2#(UInt#(19), UInt#(19)) coefficient = getExpCoefficient(interval);
	return PwlLaneStage1{
		valid: valid && mode == PWL_EXP2,
		integerPart: truncate(expInteger),
		underflow: expInteger > 18,
		base: tpl_1(coefficient),
		delta: tpl_2(coefficient),
		residual: residual
		};
endfunction


module mkPwlArray(PwlArrayIfc);
	FIFOF#(PwlArrayRequest) requestQ <- mkSizedFIFOF(2);
	FIFOF#(PwlStage1) stage1Q <- mkSizedFIFOF(2);
	FIFOF#(PwlStage2) stage2Q <- mkSizedFIFOF(2);
	FIFOF#(PwlArrayResponse) responseQ <- mkSizedFIFOF(2);

	//------------------------------------------------------------------------------------
	// Stage 1: eight dual-mode lanes and eight exp-only lanes
	//------------------------------------------------------------------------------------
	rule process1;
		PwlArrayRequest request = requestQ.first;
		requestQ.deq;
		Vector#(NumPE_Profiler, PwlLaneStage1) lane = newVector;
		for ( Integer i = 0; i < 8; i = i + 1 ) begin
			lane[i] = prepareDualModeLane(request.mode,
						  request.value[i],
						  request.validMask[i] == 1);
		end
		for ( Integer i = 8; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			lane[i] = prepareExpOnlyLane(request.mode,
						 request.value[i],
						 request.validMask[i] == 1);
		end
		stage1Q.enq(PwlStage1{
			mode: request.mode,
			lane: lane
			});
	endrule

	//------------------------------------------------------------------------------------
	// Stage 2: one interpolation multiplier per arithmetic lane
	//------------------------------------------------------------------------------------
	rule process2;
		PwlStage1 inputValue = stage1Q.first;
		stage1Q.deq;
		Vector#(NumPE_Profiler, PwlLaneStage2) lane = newVector;
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			UInt#(27) product = zeroExtend(inputValue.lane[i].delta) *
						zeroExtend(unpack(inputValue.lane[i].residual));
			lane[i] = PwlLaneStage2{
				valid: inputValue.lane[i].valid,
				integerPart: inputValue.lane[i].integerPart,
				underflow: inputValue.lane[i].underflow,
				base: inputValue.lane[i].base,
				product: product
				};
		end
		stage2Q.enq(PwlStage2{
			mode: inputValue.mode,
			lane: lane
			});
	endrule

	//------------------------------------------------------------------------------------
	// Stage 3: emit Q12 log values or Q18 exponential weights
	//------------------------------------------------------------------------------------
	rule process3;
		PwlStage2 inputValue = stage2Q.first;
		stage2Q.deq;
		PwlArrayResponse response = PwlArrayResponse{value: replicate(0)};
		for ( Integer i = 0; i < valueOf(NumPE_Profiler); i = i + 1 ) begin
			WeightValue value = 0;
			UInt#(20) correction = truncate((inputValue.lane[i].product + 128) >> 8);
			if ( inputValue.lane[i].valid ) begin
				if ( inputValue.mode == PWL_LOG2 ) begin
					UInt#(19) fractionQ18 = inputValue.lane[i].base +
								 truncate(correction);
					UInt#(13) fractionQ12 = truncate((fractionQ18 + 32) >> 6);
					UInt#(6) adjustedInteger =
						zeroExtend(inputValue.lane[i].integerPart);
					UInt#(12) adjustedFraction = truncate(fractionQ12);
					if ( fractionQ12 >= 4096 ) begin
						adjustedInteger = adjustedInteger + 1;
						adjustedFraction = truncate(fractionQ12 - 4096);
					end
					UInt#(18) combinedValue =
						(zeroExtend(adjustedInteger) << 12) |
						 zeroExtend(adjustedFraction);
					LogValue logValue = truncate(combinedValue);
					value = zeroExtend(logValue);
				end else if ( !inputValue.lane[i].underflow ) begin
					WeightValue fractionQ18 = inputValue.lane[i].base -
								       truncate(correction);
					value = boundedShiftRight19(fractionQ18,
								   inputValue.lane[i].integerPart);
				end
			end
			response.value[i] = value;
		end
		responseQ.enq(response);
	endrule

	method Action put(PwlArrayRequest request);
		requestQ.enq(request);
	endmethod

	method ActionValue#(PwlArrayResponse) get;
		PwlArrayResponse response = responseQ.first;
		responseQ.deq;
		return response;
	endmethod
endmodule

endpackage
