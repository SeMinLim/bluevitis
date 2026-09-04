import Axi4LiteControllerXrt::*;
import Axi4MemoryMaster::*;

import Clocks::*;
import FIFOF::*;

import KernelMain::*;


interface KernelTopIfc;
	(* always_ready *)
	interface Axi4MemoryMasterPinsIfc#(64, 512) in;
	(* always_ready *)
	interface Axi4MemoryMasterPinsIfc#(64, 512) out;
	(* always_ready *)
	interface Axi4LiteControllerXrtPinsIfc#(12, 32) s_axi_control;
	(* always_ready *)
	method Bool interrupt;
endinterface

(* synthesize *)
(* default_reset="ap_rst_n", default_clock_osc="ap_clk" *)
module kernel(KernelTopIfc);
	Clock defaultClock <- exposeCurrentClock;
	Reset defaultReset <- exposeCurrentReset;

	Axi4LiteControllerXrtIfc#(12, 32) axi4control <-
		mkAxi4LiteControllerXrt(defaultClock, defaultReset);
	Axi4ReadMasterIfc#(64, 512) inputMaster <- mkAxi4ReadMaster_64_512;
	Axi4WriteMasterIfc#(64, 512) outputMaster <- mkAxi4WriteMaster_64_512;
	KernelMainIfc kernelMain <- mkKernelMain;

	Reg#(Bool) startedR <- mkReg(False);
	Reg#(Bool) lastApStartR <- mkReg(False);
	FIFOF#(Bit#(32)) startQ <- mkFIFOF;
	Reg#(Bool) kernelDonePendingR <- mkReg(False);

	rule assertControl ( !startedR && !startQ.notEmpty );
		axi4control.ap_idle;
	endrule

	rule captureStart;
		Bool currentStart = axi4control.ap_start;
		if ( !lastApStartR && currentStart ) begin
			startQ.enq(axi4control.scalar00);
		end
		lastApStartR <= currentStart;
	endrule

	rule launchStart ( !startedR );
		Bit#(32) startParam = startQ.first;
		startQ.deq;
		kernelMain.start(startParam);
		startedR <= True;
		kernelDonePendingR <= False;
	endrule

	rule captureDone ( startedR && !kernelDonePendingR );
		Bool done <- kernelMain.done;
		if ( done ) kernelDonePendingR <= True;
	endrule

	// Report completion only after both AXI streams are completely drained.
	rule finishKernel ( startedR && kernelDonePendingR &&
			    inputMaster.idle && outputMaster.idle );
		axi4control.ap_done;
		axi4control.ap_ready;
		startedR <= False;
		kernelDonePendingR <= False;
	endrule

	rule relayInputReadReq ( startedR );
		let request <- kernelMain.inputReadReq;
		inputMaster.readReq(axi4control.mem_addr + request.addr,
				    zeroExtend(request.bytes));
	endrule

	rule relayInputReadWord ( startedR );
		let word <- inputMaster.read;
		kernelMain.inputReadWord(word);
	endrule

	rule relayOutputWriteReq ( startedR );
		let request <- kernelMain.outputWriteReq;
		outputMaster.writeReq(axi4control.file_addr + request.addr,
				      zeroExtend(request.bytes));
	endrule

	rule relayOutputWriteWord ( startedR );
		let word <- kernelMain.outputWriteWord;
		outputMaster.write(word);
	endrule

	interface in = inputMaster.pins;
	interface out = outputMaster.pins;
	interface s_axi_control = axi4control.pins;
	interface interrupt = axi4control.interrupt;
endmodule
