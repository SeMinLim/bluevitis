package Axi4MemoryMaster;

import FIFOF::*;
import SpecialFIFOs::*;
import RWire::*;


interface Axi4MemoryMasterPinsIfc#(numeric type addrSz, numeric type dataSz);
	(* always_ready, result="awvalid" *)
	method Bool awvalid;
	(* always_ready, always_enabled, prefix="" *)
	method Action address_write((* port="awready" *) Bool awready);
	(* always_ready, result="awaddr" *)
	method Bit#(addrSz) awaddr;
	(* always_ready, result="awlen" *)
	method Bit#(8) awlen;

	(* always_ready, result="wvalid" *)
	method Bool wvalid;
	(* always_ready, always_enabled, prefix="" *)
	method Action data_write((* port="wready" *) Bool wready);
	(* always_ready, result="wdata" *)
	method Bit#(dataSz) wdata;
	(* always_ready, result="wstrb" *)
	method Bit#(TDiv#(dataSz, 8)) wstrb;
	(* always_ready, result="wlast" *)
	method Bool wlast;

	(* always_ready, always_enabled, prefix="" *)
	method Action write_resp_valid((* port="bvalid" *) Bool bvalid);
	(* always_ready, result="bready" *)
	method Bool bready;

	(* always_ready, result="arvalid" *)
	method Bool arvalid;
	(* always_ready, always_enabled, prefix="" *)
	method Action read_address_ready((* port="arready" *) Bool arready);
	(* always_ready, result="araddr" *)
	method Bit#(addrSz) araddr;
	(* always_ready, result="arlen" *)
	method Bit#(8) arlen;

	(* always_ready, always_enabled, prefix="" *)
	method Action read_data_valid((* port="rvalid" *) Bool rvalid);
	(* always_ready, result="rready" *)
	method Bool rready;
	(* always_ready, always_enabled, prefix="" *)
	method Action read_data((* port="rdata" *) Bit#(dataSz) rdata);
	(* always_ready, always_enabled, prefix="" *)
	method Action read_data_last((* port="rlast" *) Bool rlast);
endinterface

interface Axi4ReadMasterIfc#(numeric type addrSz, numeric type dataSz);
	interface Axi4MemoryMasterPinsIfc#(addrSz, dataSz) pins;
	method Action readReq(Bit#(addrSz) addr, Bit#(addrSz) size);
	method ActionValue#(Bit#(dataSz)) read;
	method Bool idle;
endinterface

interface Axi4WriteMasterIfc#(numeric type addrSz, numeric type dataSz);
	interface Axi4MemoryMasterPinsIfc#(addrSz, dataSz) pins;
	method Action writeReq(Bit#(addrSz) addr, Bit#(addrSz) size);
	method Action write(Bit#(dataSz) data);
	method Bool idle;
endinterface


(* synthesize *)
module mkAxi4ReadMaster_64_512(Axi4ReadMasterIfc#(64, 512));
	let moduleValue <- mkAxi4ReadMaster;
	return moduleValue;
endmodule

module mkAxi4ReadMaster(Axi4ReadMasterIfc#(addrSz, dataSz))
	provisos(
		Add#(a__, 8, addrSz),
		Add#(b__, 512, dataSz)
	);
	Integer maxBurstWords = min(256, (4096 / (valueOf(dataSz) / 8)));
	Integer maxBurstBytes = maxBurstWords * (valueOf(dataSz) / 8);
	Integer wordByteSizeBits = valueOf(TLog#(dataSz)) - 3;

	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(addrSz))) readReqQ <- mkFIFOF;
	FIFOF#(Bit#(dataSz)) readWordQ <- mkSizedFIFOF(16);
	Reg#(Bool) splitOnR <- mkReg(False);
	Reg#(Bit#(addrSz)) splitAddressR <- mkReg(0);
	Reg#(Bit#(addrSz)) splitBytesLeftR <- mkReg(0);

	Reg#(Bool) addressValidR <- mkReg(False);
	Reg#(Bit#(addrSz)) addressR <- mkReg(0);
	Reg#(Bit#(8)) lengthR <- mkReg(0);
	Reg#(UInt#(16)) acceptedBurstNumR <- mkReg(0);
	Reg#(UInt#(16)) completedBurstNumR <- mkReg(0);

	PulseWire addressReadyW <- mkPulseWire;
	PulseWire readDataValidW <- mkPulseWire;
	PulseWire readDataLastW <- mkPulseWire;
	RWire#(Bit#(dataSz)) readDataW <- mkRWire;

	//------------------------------------------------------------------------------------
	// Hold each AXI read address until the slave accepts it
	//------------------------------------------------------------------------------------
	rule manageReadAddress;
		Bool addressConsumed = addressValidR && addressReadyW;
		Bool addressSlotAvailable = !addressValidR || addressConsumed;
		Bool sourceValid = splitOnR || readReqQ.notEmpty;

		if ( addressConsumed ) acceptedBurstNumR <= acceptedBurstNumR + 1;
		if ( addressSlotAvailable ) begin
			if ( sourceValid ) begin
				Bit#(addrSz) sourceAddress = splitAddressR;
				Bit#(addrSz) sourceBytes = splitBytesLeftR;
				if ( !splitOnR ) begin
					Tuple2#(Bit#(addrSz), Bit#(addrSz)) request = readReqQ.first;
					readReqQ.deq;
					sourceAddress = tpl_1(request);
					sourceBytes = tpl_2(request);
				end

				Bit#(addrSz) burstBytes = sourceBytes > fromInteger(maxBurstBytes) ?
					fromInteger(maxBurstBytes) : sourceBytes;
				Bit#(addrSz) burstWords = burstBytes >> wordByteSizeBits;
				addressR <= sourceAddress;
				lengthR <= truncate(burstWords - 1);
				addressValidR <= True;
				if ( sourceBytes > fromInteger(maxBurstBytes) ) begin
					splitOnR <= True;
					splitAddressR <= sourceAddress + fromInteger(maxBurstBytes);
					splitBytesLeftR <= sourceBytes - fromInteger(maxBurstBytes);
				end else begin
					splitOnR <= False;
					splitBytesLeftR <= 0;
				end
			end else if ( addressConsumed ) begin
				addressValidR <= False;
			end
		end
	endrule

	//------------------------------------------------------------------------------------
	// Capture read data only when the local FIFO can accept it
	//------------------------------------------------------------------------------------
	rule captureReadData ( readWordQ.notFull && readDataValidW );
		readWordQ.enq(fromMaybe(0, readDataW.wget));
		if ( readDataLastW ) completedBurstNumR <= completedBurstNumR + 1;
	endrule

	interface Axi4MemoryMasterPinsIfc pins;
		method Bool awvalid;
			return False;
		endmethod
		method Action address_write(Bool awready);
			noAction;
		endmethod
		method Bit#(addrSz) awaddr;
			return 0;
		endmethod
		method Bit#(8) awlen;
			return 0;
		endmethod

		method Bool wvalid;
			return False;
		endmethod
		method Action data_write(Bool wready);
			noAction;
		endmethod
		method Bit#(dataSz) wdata;
			return 0;
		endmethod
		method Bit#(TDiv#(dataSz, 8)) wstrb;
			return 0;
		endmethod
		method Bool wlast;
			return False;
		endmethod

		method Action write_resp_valid(Bool bvalid);
			noAction;
		endmethod
		method Bool bready;
			return True;
		endmethod

		method Bool arvalid;
			return addressValidR;
		endmethod
		method Action read_address_ready(Bool arready);
			if ( arready ) addressReadyW.send;
		endmethod
		method Bit#(addrSz) araddr;
			return addressR;
		endmethod
		method Bit#(8) arlen;
			return lengthR;
		endmethod

		method Action read_data_valid(Bool rvalid);
			if ( rvalid ) readDataValidW.send;
		endmethod
		method Bool rready;
			return readWordQ.notFull;
		endmethod
		method Action read_data(Bit#(dataSz) rdata);
			readDataW.wset(rdata);
		endmethod
		method Action read_data_last(Bool rlast);
			if ( rlast ) readDataLastW.send;
		endmethod
	endinterface

	method Action readReq(Bit#(addrSz) addr, Bit#(addrSz) size);
		readReqQ.enq(tuple2(addr, size));
	endmethod

	method ActionValue#(Bit#(dataSz)) read;
		Bit#(dataSz) value = readWordQ.first;
		readWordQ.deq;
		return value;
	endmethod

	method Bool idle;
		return !readReqQ.notEmpty &&
		       !splitOnR &&
		       !addressValidR &&
		       !readWordQ.notEmpty &&
		       acceptedBurstNumR == completedBurstNumR;
	endmethod
endmodule


(* synthesize *)
module mkAxi4WriteMaster_64_512(Axi4WriteMasterIfc#(64, 512));
	let moduleValue <- mkAxi4WriteMaster;
	return moduleValue;
endmodule

module mkAxi4WriteMaster(Axi4WriteMasterIfc#(addrSz, dataSz))
	provisos(
		Add#(a__, 8, addrSz),
		Add#(b__, 512, dataSz)
	);
	Integer maxBurstWords = min(256, (4096 / (valueOf(dataSz) / 8)));
	Integer maxBurstBytes = maxBurstWords * (valueOf(dataSz) / 8);
	Integer wordByteSizeBits = valueOf(TLog#(dataSz)) - 3;

	FIFOF#(Tuple2#(Bit#(addrSz), Bit#(addrSz))) writeReqQ <- mkFIFOF;
	FIFOF#(Bit#(8)) burstLengthQ <- mkPipelineFIFOF;
	FIFOF#(Bit#(dataSz)) writeWordQ <- mkSizedFIFOF(16);
	Reg#(Bool) splitOnR <- mkReg(False);
	Reg#(Bit#(addrSz)) splitAddressR <- mkReg(0);
	Reg#(Bit#(addrSz)) splitBytesLeftR <- mkReg(0);

	Reg#(Bool) addressValidR <- mkReg(False);
	Reg#(Bit#(addrSz)) addressR <- mkReg(0);
	Reg#(Bit#(8)) lengthR <- mkReg(0);
	Reg#(UInt#(16)) acceptedBurstNumR <- mkReg(0);
	Reg#(UInt#(16)) completedBurstNumR <- mkReg(0);

	Reg#(Bool) dataValidR <- mkReg(False);
	Reg#(Bit#(dataSz)) dataR <- mkReg(0);
	Reg#(Bool) dataLastR <- mkReg(False);
	Reg#(Bit#(8)) remainingBeatNumR <- mkReg(0);

	PulseWire addressReadyW <- mkPulseWire;
	PulseWire dataReadyW <- mkPulseWire;
	PulseWire writeResponseW <- mkPulseWire;

	//------------------------------------------------------------------------------------
	// Hold each AXI write address until the slave accepts it
	//------------------------------------------------------------------------------------
	rule manageWriteAddress;
		Bool addressConsumed = addressValidR && addressReadyW && burstLengthQ.notFull;
		Bool addressSlotAvailable = !addressValidR || addressConsumed;
		Bool sourceValid = splitOnR || writeReqQ.notEmpty;

		if ( addressConsumed ) begin
			burstLengthQ.enq(lengthR);
			acceptedBurstNumR <= acceptedBurstNumR + 1;
		end
		if ( addressSlotAvailable ) begin
			if ( sourceValid ) begin
				Bit#(addrSz) sourceAddress = splitAddressR;
				Bit#(addrSz) sourceBytes = splitBytesLeftR;
				if ( !splitOnR ) begin
					Tuple2#(Bit#(addrSz), Bit#(addrSz)) request = writeReqQ.first;
					writeReqQ.deq;
					sourceAddress = tpl_1(request);
					sourceBytes = tpl_2(request);
				end

				Bit#(addrSz) burstBytes = sourceBytes > fromInteger(maxBurstBytes) ?
					fromInteger(maxBurstBytes) : sourceBytes;
				Bit#(addrSz) burstWords = burstBytes >> wordByteSizeBits;
				addressR <= sourceAddress;
				lengthR <= truncate(burstWords - 1);
				addressValidR <= True;
				if ( sourceBytes > fromInteger(maxBurstBytes) ) begin
					splitOnR <= True;
					splitAddressR <= sourceAddress + fromInteger(maxBurstBytes);
					splitBytesLeftR <= sourceBytes - fromInteger(maxBurstBytes);
				end else begin
					splitOnR <= False;
					splitBytesLeftR <= 0;
				end
			end else if ( addressConsumed ) begin
				addressValidR <= False;
			end
		end
	endrule

	//------------------------------------------------------------------------------------
	// Maintain a stable AXI write-data beat and refill it on every handshake
	//------------------------------------------------------------------------------------
	rule manageWriteData;
		Bool dataConsumed = dataValidR && dataReadyW;
		Bool dataSlotAvailable = !dataValidR || dataConsumed;
		Bool currentBurstAvailable = remainingBeatNumR != 0;
		Bool newBurstAvailable = burstLengthQ.notEmpty;
		Bool sourceValid = writeWordQ.notEmpty &&
				   (currentBurstAvailable || newBurstAvailable);

		if ( dataSlotAvailable ) begin
			if ( sourceValid ) begin
				Bit#(8) remainingAfterCurrent = remainingBeatNumR;
				if ( currentBurstAvailable ) begin
					remainingAfterCurrent = remainingBeatNumR - 1;
				end else begin
					remainingAfterCurrent = burstLengthQ.first;
					burstLengthQ.deq;
				end
				dataR <= writeWordQ.first;
				writeWordQ.deq;
				dataLastR <= remainingAfterCurrent == 0;
				remainingBeatNumR <= remainingAfterCurrent;
				dataValidR <= True;
			end else if ( dataConsumed ) begin
				dataValidR <= False;
			end
		end
	endrule

	rule countWriteResponse ( writeResponseW );
		completedBurstNumR <= completedBurstNumR + 1;
	endrule

	interface Axi4MemoryMasterPinsIfc pins;
		method Bool awvalid;
			return addressValidR && burstLengthQ.notFull;
		endmethod
		method Action address_write(Bool awready);
			if ( awready ) addressReadyW.send;
		endmethod
		method Bit#(addrSz) awaddr;
			return addressR;
		endmethod
		method Bit#(8) awlen;
			return lengthR;
		endmethod

		method Bool wvalid;
			return dataValidR;
		endmethod
		method Action data_write(Bool wready);
			if ( wready ) dataReadyW.send;
		endmethod
		method Bit#(dataSz) wdata;
			return dataR;
		endmethod
		method Bit#(TDiv#(dataSz, 8)) wstrb;
			return -1;
		endmethod
		method Bool wlast;
			return dataLastR;
		endmethod

		method Action write_resp_valid(Bool bvalid);
			if ( bvalid ) writeResponseW.send;
		endmethod
		method Bool bready;
			return True;
		endmethod

		method Bool arvalid;
			return False;
		endmethod
		method Action read_address_ready(Bool arready);
			noAction;
		endmethod
		method Bit#(addrSz) araddr;
			return 0;
		endmethod
		method Bit#(8) arlen;
			return 0;
		endmethod

		method Action read_data_valid(Bool rvalid);
			noAction;
		endmethod
		method Bool rready;
			return False;
		endmethod
		method Action read_data(Bit#(dataSz) rdata);
			noAction;
		endmethod
		method Action read_data_last(Bool rlast);
			noAction;
		endmethod
	endinterface

	method Action writeReq(Bit#(addrSz) addr, Bit#(addrSz) size);
		writeReqQ.enq(tuple2(addr, size));
	endmethod

	method Action write(Bit#(dataSz) data);
		writeWordQ.enq(data);
	endmethod

	method Bool idle;
		return !writeReqQ.notEmpty &&
		       !splitOnR &&
		       !addressValidR &&
		       !burstLengthQ.notEmpty &&
		       !writeWordQ.notEmpty &&
		       !dataValidR &&
		       remainingBeatNumR == 0 &&
		       acceptedBurstNumR == completedBurstNumR;
	endmethod
endmodule

endpackage
