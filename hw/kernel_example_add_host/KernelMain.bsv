import FIFO::*;
import Vector::*;
import URAM::*;
import Float32::*;

typedef 0 MemPortAddrStart_0;
typedef 0 ResultAddrStart;
typedef 2 MemPortCnt;

typedef struct {
   Bit#(64) addr;
   Bit#(32) bytes;
} MemPortReq deriving (Eq, Bits);

typedef enum {
   ST_IDLE,
   ST_REQ_INPUT,
   ST_RECV_INPUT,
   ST_REQ_URAM_IN,
   ST_RECV_URAM_IN,
   ST_ADD_ENQ,
   ST_ADD_GET,
   ST_SUB_ENQ,
   ST_SUB_GET,
   ST_MUL_ENQ,
   ST_MUL_GET,
   ST_DIV_ENQ,
   ST_DIV_GET,
   ST_SQRT_ENQ,
   ST_SQRT_GET,
   ST_EXP_ENQ,
   ST_EXP_GET,
   ST_FMA_ENQ,
   ST_FMA_GET,
   ST_SQRTCUBE_ENQ,
   ST_SQRTCUBE_GET,
   ST_PACK_RESULT,
   ST_STORE_RESULT_URAM,
   ST_REQ_URAM_OUT,
   ST_RECV_URAM_OUT,
   ST_REQ_WRITE,
   ST_WRITE_WORD,
   ST_DONE
} TestState deriving (Bits, Eq);

interface MemPortIfc;
   method ActionValue#(MemPortReq) readReq;
   method ActionValue#(MemPortReq) writeReq;
   method ActionValue#(Bit#(512)) writeWord;
   method Action readWord(Bit#(512) word);
endinterface

interface KernelMainIfc;
   method Action start(Bit#(32) param);
   method ActionValue#(Bool) done;
   interface Vector#(MemPortCnt, MemPortIfc) mem;
endinterface

module mkKernelMain(KernelMainIfc);

   // --------------------------------------------------------------------------
   // Constants
   // --------------------------------------------------------------------------
   Bit#(32) kMagic         = 32'h46503332; // "FP32"
   Bit#(32) kInputMagic0   = 32'h13579BDF;
   Bit#(32) kInputMagic1   = 32'h2468ACE0;
   Bit#(32) kAddExpected   = 32'h40700000; // 3.75
   Bit#(32) kSubExpected   = 32'h40500000; // 3.25
   Bit#(32) kMulExpected   = 32'hC0400000; // -3.0
   Bit#(32) kDivExpected   = 32'h40400000; // 3.0
   Bit#(32) kSqrtExpected  = 32'h40400000; // 3.0
   Bit#(32) kExpExpected   = 32'h3F800000; // exp(0) = 1.0
   Bit#(32) kFmaExpected   = 32'h40600000; // 3.5
   Bit#(32) kScubeExpected = 32'h41000000; // 8.0

   // --------------------------------------------------------------------------
   // Start / done
   // --------------------------------------------------------------------------
   FIFO#(Bool) startQ <- mkFIFO;
   FIFO#(Bool) doneQ  <- mkFIFO;

   Reg#(Bool) started <- mkReg(False);
   Reg#(TestState) state <- mkReg(ST_IDLE);

   // --------------------------------------------------------------------------
   // Cycle counter
   // --------------------------------------------------------------------------
   Reg#(Bit#(32)) cycleCounter <- mkReg(0);
   Reg#(Bit#(32)) cycleStart   <- mkReg(0);

   rule incCycle;
      cycleCounter <= cycleCounter + 1;
   endrule

   // --------------------------------------------------------------------------
   // Memory-port queues
   // --------------------------------------------------------------------------
   Vector#(MemPortCnt, FIFO#(MemPortReq))   readReqQs   <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(MemPortReq))   writeReqQs  <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(Bit#(512)))    writeWordQs <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(Bit#(512)))    readWordQs  <- replicateM(mkFIFO);

   // --------------------------------------------------------------------------
   // URAM staging
   // --------------------------------------------------------------------------
   URAM_Configure cfg = defaultValue;
   URAM2Port#(Bit#(10), Bit#(512)) uramIn  <- mkURAM2Server(cfg);
   URAM2Port#(Bit#(10), Bit#(512)) uramOut <- mkURAM2Server(cfg);

   Reg#(Bit#(512)) inputWord  <- mkReg(0);
   Reg#(Bit#(512)) resultWord <- mkReg(0);
   Reg#(Bool)      hostPathPass <- mkReg(False);

   // --------------------------------------------------------------------------
   // Floating-point modules
   // --------------------------------------------------------------------------
   FpPairIfc#(32)    fpAdd       <- mkFpAdd32;
   FpPairIfc#(32)    fpSub       <- mkFpSub32;
   FpPairIfc#(32)    fpMult      <- mkFpMult32;
   FpPairIfc#(32)    fpDiv       <- mkFpDiv32;
   FpFilterIfc#(32)  fpSqrt      <- mkFpSqrt32;
   FpFilterIfc#(32)  fpExp       <- mkFpExp32;
   FpThreeOpIfc#(32) fpFma       <- mkFpFma32;
   FpFilterIfc#(32)  fpSqrtCube  <- mkFpSqrtCube32;

   Reg#(Bit#(32)) addObs       <- mkReg(0);
   Reg#(Bit#(32)) subObs       <- mkReg(0);
   Reg#(Bit#(32)) multObs      <- mkReg(0);
   Reg#(Bit#(32)) divObs       <- mkReg(0);
   Reg#(Bit#(32)) sqrtObs      <- mkReg(0);
   Reg#(Bit#(32)) expObs       <- mkReg(0);
   Reg#(Bit#(32)) fmaObs       <- mkReg(0);
   Reg#(Bit#(32)) sqrtCubeObs  <- mkReg(0);
   Reg#(Bit#(8))  passMask     <- mkReg(0);

   // --------------------------------------------------------------------------
   // System start
   // --------------------------------------------------------------------------
   rule systemStart (!started);
      startQ.deq;
      started      <= True;
      state        <= ST_REQ_INPUT;
      cycleStart   <= cycleCounter;
      inputWord    <= 0;
      resultWord   <= 0;
      hostPathPass <= False;
      addObs       <= 0;
      subObs       <= 0;
      multObs      <= 0;
      divObs       <= 0;
      sqrtObs      <= 0;
      expObs       <= 0;
      fmaObs       <= 0;
      sqrtCubeObs  <= 0;
      passMask     <= 0;
   endrule

   // --------------------------------------------------------------------------
   // Read one 512-bit input beat from the direct host connection and store it
   // into URAM. Then read it back from URAM before running the tests.
   // --------------------------------------------------------------------------
   rule reqInput (started && state == ST_REQ_INPUT);
      readReqQs[0].enq(MemPortReq{addr: 64'd0, bytes: 32'd64});
      state <= ST_RECV_INPUT;
   endrule

   rule recvInput (started && state == ST_RECV_INPUT);
      let w = readWordQs[0].first;
      readWordQs[0].deq;
      inputWord <= w;
      uramIn.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 0, datain: w}
      );
      state <= ST_REQ_URAM_IN;
   endrule

   rule reqReadUramIn (started && state == ST_REQ_URAM_IN);
      uramIn.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 0, datain: ?}
      );
      state <= ST_RECV_URAM_IN;
   endrule

   rule recvReadUramIn (started && state == ST_RECV_URAM_IN);
      let w <- uramIn.portB.response.get;
      inputWord <= w;
      hostPathPass <= (w[479:448] == kInputMagic0) && (w[511:480] == kInputMagic1);
      state <= ST_ADD_ENQ;
   endrule

   // --------------------------------------------------------------------------
   // 8 module tests, sequentially issued.
   // Input lanes in the single 512-bit word:
   //   0:add_a  1:add_b  2:sub_a  3:sub_b
   //   4:mul_a  5:mul_b  6:div_a  7:div_b
   //   8:sqrt_a 9:exp_a 10:fma_a 11:fma_b 12:fma_c 13:sqrtcube_a
   //   14:input_magic0 15:input_magic1
   // --------------------------------------------------------------------------
   rule doAddEnq (started && state == ST_ADD_ENQ);
      fpAdd.enq(inputWord[31:0], inputWord[63:32]);
      state <= ST_ADD_GET;
   endrule

   rule doAddGet (started && state == ST_ADD_GET);
      let v = fpAdd.first;
      fpAdd.deq;
      addObs <= v;
      if (v == kAddExpected)
         passMask <= passMask | 8'h01;
      state <= ST_SUB_ENQ;
   endrule

   rule doSubEnq (started && state == ST_SUB_ENQ);
      fpSub.enq(inputWord[95:64], inputWord[127:96]);
      state <= ST_SUB_GET;
   endrule

   rule doSubGet (started && state == ST_SUB_GET);
      let v = fpSub.first;
      fpSub.deq;
      subObs <= v;
      if (v == kSubExpected)
         passMask <= passMask | 8'h02;
      state <= ST_MUL_ENQ;
   endrule

   rule doMulEnq (started && state == ST_MUL_ENQ);
      fpMult.enq(inputWord[159:128], inputWord[191:160]);
      state <= ST_MUL_GET;
   endrule

   rule doMulGet (started && state == ST_MUL_GET);
      let v = fpMult.first;
      fpMult.deq;
      multObs <= v;
      if (v == kMulExpected)
         passMask <= passMask | 8'h04;
      state <= ST_DIV_ENQ;
   endrule

   rule doDivEnq (started && state == ST_DIV_ENQ);
      fpDiv.enq(inputWord[223:192], inputWord[255:224]);
      state <= ST_DIV_GET;
   endrule

   rule doDivGet (started && state == ST_DIV_GET);
      let v = fpDiv.first;
      fpDiv.deq;
      divObs <= v;
      if (v == kDivExpected)
         passMask <= passMask | 8'h08;
      state <= ST_SQRT_ENQ;
   endrule

   rule doSqrtEnq (started && state == ST_SQRT_ENQ);
      fpSqrt.enq(inputWord[287:256]);
      state <= ST_SQRT_GET;
   endrule

   rule doSqrtGet (started && state == ST_SQRT_GET);
      let v = fpSqrt.first;
      fpSqrt.deq;
      sqrtObs <= v;
      if (v == kSqrtExpected)
         passMask <= passMask | 8'h10;
      state <= ST_EXP_ENQ;
   endrule

   rule doExpEnq (started && state == ST_EXP_ENQ);
      fpExp.enq(inputWord[319:288]);
      state <= ST_EXP_GET;
   endrule

   rule doExpGet (started && state == ST_EXP_GET);
      let v = fpExp.first;
      fpExp.deq;
      expObs <= v;
      if (v == kExpExpected)
         passMask <= passMask | 8'h20;
      state <= ST_FMA_ENQ;
   endrule

   rule doFmaEnq (started && state == ST_FMA_ENQ);
      fpFma.enq(inputWord[351:320], inputWord[383:352], inputWord[415:384], True);
      state <= ST_FMA_GET;
   endrule

   rule doFmaGet (started && state == ST_FMA_GET);
      let v = fpFma.first;
      fpFma.deq;
      fmaObs <= v;
      if (v == kFmaExpected)
         passMask <= passMask | 8'h40;
      state <= ST_SQRTCUBE_ENQ;
   endrule

   rule doSqrtCubeEnq (started && state == ST_SQRTCUBE_ENQ);
      fpSqrtCube.enq(inputWord[447:416]);
      state <= ST_SQRTCUBE_GET;
   endrule

   rule doSqrtCubeGet (started && state == ST_SQRTCUBE_GET);
      let v = fpSqrtCube.first;
      fpSqrtCube.deq;
      sqrtCubeObs <= v;
      if (v == kScubeExpected)
         passMask <= passMask | 8'h80;
      state <= ST_PACK_RESULT;
   endrule

   // --------------------------------------------------------------------------
   // Pack the result into one 512-bit beat, stage it through a second URAM, and
   // then write it back through the direct host connection.
   // --------------------------------------------------------------------------
   rule packResult (started && state == ST_PACK_RESULT);
      Bit#(32) hostPass32 = zeroExtend(pack(hostPathPass));
      Bit#(32) status     = (hostPathPass && (passMask == 8'hFF))
                              ? 32'd3
                              : (32'hBAD00000 | zeroExtend(passMask));
      Bit#(32) cycles     = cycleCounter - cycleStart;

      resultWord <= {
         32'h00000000,        // lane 15
         hostPass32,          // lane 14
         inputWord[511:480],  // lane 13, echo input magic1 after URAM
         inputWord[479:448],  // lane 12, echo input magic0 after URAM
         sqrtCubeObs,         // lane 11
         fmaObs,              // lane 10
         expObs,              // lane  9
         sqrtObs,             // lane  8
         divObs,              // lane  7
         multObs,             // lane  6
         subObs,              // lane  5
         addObs,              // lane  4
         cycles,              // lane  3
         zeroExtend(passMask),// lane  2
         status,              // lane  1
         kMagic               // lane  0
      };
      state <= ST_STORE_RESULT_URAM;
   endrule

   rule storeResultUram (started && state == ST_STORE_RESULT_URAM);
      uramOut.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 0, datain: resultWord}
      );
      state <= ST_REQ_URAM_OUT;
   endrule

   rule reqReadUramOut (started && state == ST_REQ_URAM_OUT);
      uramOut.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 0, datain: ?}
      );
      state <= ST_RECV_URAM_OUT;
   endrule

   rule recvReadUramOut (started && state == ST_RECV_URAM_OUT);
      let w <- uramOut.portB.response.get;
      resultWord <= w;
      state <= ST_REQ_WRITE;
   endrule

   rule reqWriteResult (started && state == ST_REQ_WRITE);
      writeReqQs[1].enq(MemPortReq{addr: 64'd0, bytes: 32'd64});
      state <= ST_WRITE_WORD;
   endrule

   rule writeResult (started && state == ST_WRITE_WORD);
      writeWordQs[1].enq(resultWord);
      state   <= ST_DONE;
      started <= False;
      doneQ.enq(True);
   endrule

   // --------------------------------------------------------------------------
   // Interface
   // --------------------------------------------------------------------------
   Vector#(MemPortCnt, MemPortIfc) mem_;
   for (Integer i = 0; i < valueOf(MemPortCnt); i = i + 1) begin
      mem_[i] = interface MemPortIfc;
         method ActionValue#(MemPortReq) readReq;
            let v = readReqQs[i].first;
            readReqQs[i].deq;
            return v;
         endmethod

         method ActionValue#(MemPortReq) writeReq;
            let v = writeReqQs[i].first;
            writeReqQs[i].deq;
            return v;
         endmethod

         method ActionValue#(Bit#(512)) writeWord;
            let v = writeWordQs[i].first;
            writeWordQs[i].deq;
            return v;
         endmethod

         method Action readWord(Bit#(512) word);
            readWordQs[i].enq(word);
         endmethod
      endinterface;
   end

   method Action start(Bit#(32) param) if (!started);
      startQ.enq(True);
   endmethod

   method ActionValue#(Bool) done;
      let v = doneQ.first;
      doneQ.deq;
      return v;
   endmethod

   interface mem = mem_;
endmodule
