import FIFO::*;
import Vector::*;
import URAM::*;
import Float32::*;
import Float64::*;

typedef 0 MemPortAddrStart_0;
typedef 0 ResultAddrStart;
typedef 2 MemPortCnt;

typedef struct {
   Bit#(64) addr;
   Bit#(32) bytes;
} MemPortReq deriving (Eq, Bits);

typedef enum {
   ST_IDLE,

   ST_REQ_INPUT0,
   ST_RECV_INPUT0,
   ST_REQ_INPUT1,
   ST_RECV_INPUT1,
   ST_REQ_INPUT2,
   ST_RECV_INPUT2,

   ST_REQ_URAM_IN0,
   ST_RECV_URAM_IN0,
   ST_REQ_URAM_IN1,
   ST_RECV_URAM_IN1,
   ST_REQ_URAM_IN2,
   ST_RECV_URAM_IN2,

   ST_ADD32_ENQ,
   ST_ADD32_GET,
   ST_SUB32_ENQ,
   ST_SUB32_GET,
   ST_MUL32_ENQ,
   ST_MUL32_GET,
   ST_DIV32_ENQ,
   ST_DIV32_GET,
   ST_SQRT32_ENQ,
   ST_SQRT32_GET,
   ST_EXP32_ENQ,
   ST_EXP32_GET,
   ST_FMA32_ENQ,
   ST_FMA32_GET,
   ST_SQRTCUBE32_ENQ,
   ST_SQRTCUBE32_GET,

   ST_ADD64_ENQ,
   ST_ADD64_GET,
   ST_SUB64_ENQ,
   ST_SUB64_GET,
   ST_MUL64_ENQ,
   ST_MUL64_GET,
   ST_DIV64_ENQ,
   ST_DIV64_GET,
   ST_SQRT64_ENQ,
   ST_SQRT64_GET,
   ST_EXP64_ENQ,
   ST_EXP64_GET,
   ST_FMA64_ENQ,
   ST_FMA64_GET,
   ST_SQRTCUBE64_ENQ,
   ST_SQRTCUBE64_GET,

   ST_PACK_RESULT,
   ST_STORE_RESULT0_URAM,
   ST_STORE_RESULT1_URAM,
   ST_STORE_RESULT2_URAM,

   ST_REQ_URAM_OUT0,
   ST_RECV_URAM_OUT0,
   ST_REQ_URAM_OUT1,
   ST_RECV_URAM_OUT1,
   ST_REQ_URAM_OUT2,
   ST_RECV_URAM_OUT2,

   ST_REQ_WRITE0,
   ST_WRITE_WORD0,
   ST_REQ_WRITE1,
   ST_WRITE_WORD1,
   ST_REQ_WRITE2,
   ST_WRITE_WORD2,

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
   Bit#(32) kMagic32      = 32'h46505832; // "FPX2"

   Bit#(32) kInputMagic0  = 32'h13579BDF;
   Bit#(32) kInputMagic1  = 32'h2468ACE0;
   Bit#(64) kInputMagic64_0 = 64'h0123456789ABCDEF;
   Bit#(64) kInputMagic64_1 = 64'h0FEDCBA987654321;

   Bit#(32) kAddExpected32   = 32'h40700000; // 3.75
   Bit#(32) kSubExpected32   = 32'h40500000; // 3.25
   Bit#(32) kMulExpected32   = 32'hC0400000; // -3.0
   Bit#(32) kDivExpected32   = 32'h40400000; // 3.0
   Bit#(32) kSqrtExpected32  = 32'h40400000; // 3.0
   Bit#(32) kExpExpected32   = 32'h3F800000; // exp(0) = 1.0
   Bit#(32) kFmaExpected32   = 32'h40600000; // 3.5
   Bit#(32) kScubeExpected32 = 32'h41000000; // 8.0

   Bit#(64) kAddExpected64   = 64'h400E000000000000; // 3.75
   Bit#(64) kSubExpected64   = 64'h400A000000000000; // 3.25
   Bit#(64) kMulExpected64   = 64'hC008000000000000; // -3.0
   Bit#(64) kDivExpected64   = 64'h4008000000000000; // 3.0
   Bit#(64) kSqrtExpected64  = 64'h4008000000000000; // 3.0
   Bit#(64) kExpExpected64   = 64'h3FF0000000000000; // exp(0) = 1.0
   Bit#(64) kFmaExpected64   = 64'h400C000000000000; // 3.5
   Bit#(64) kScubeExpected64 = 64'h4020000000000000; // 8.0

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
   Vector#(MemPortCnt, FIFO#(MemPortReq)) readReqQs   <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(MemPortReq)) writeReqQs  <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(Bit#(512)))  writeWordQs <- replicateM(mkFIFO);
   Vector#(MemPortCnt, FIFO#(Bit#(512)))  readWordQs  <- replicateM(mkFIFO);

   // --------------------------------------------------------------------------
   // URAM staging
   // --------------------------------------------------------------------------
   URAM_Configure cfg = defaultValue;
   URAM2Port#(Bit#(10), Bit#(512)) uramIn  <- mkURAM2Server(cfg);
   URAM2Port#(Bit#(10), Bit#(512)) uramOut <- mkURAM2Server(cfg);

   Reg#(Bit#(512)) inputWord0  <- mkReg(0);
   Reg#(Bit#(512)) inputWord1  <- mkReg(0);
   Reg#(Bit#(512)) inputWord2  <- mkReg(0);

   Reg#(Bit#(512)) resultWord0 <- mkReg(0);
   Reg#(Bit#(512)) resultWord1 <- mkReg(0);
   Reg#(Bit#(512)) resultWord2 <- mkReg(0);

   Reg#(Bool) hostPathPass32 <- mkReg(False);
   Reg#(Bool) hostPathPass64 <- mkReg(False);

   // --------------------------------------------------------------------------
   // Floating-point modules
   // --------------------------------------------------------------------------
   let fpAdd32      <- Float32::mkFpAdd32;
   let fpSub32      <- Float32::mkFpSub32;
   let fpMult32     <- Float32::mkFpMult32;
   let fpDiv32      <- Float32::mkFpDiv32;
   let fpSqrt32     <- Float32::mkFpSqrt32;
   let fpExp32      <- Float32::mkFpExp32;
   let fpFma32      <- Float32::mkFpFma32;
   let fpSqrtCube32 <- Float32::mkFpSqrtCube32;

   let fpAdd64      <- Float64::mkFpAdd64;
   let fpSub64      <- Float64::mkFpSub64;
   let fpMult64     <- Float64::mkFpMult64;
   let fpDiv64      <- Float64::mkFpDiv64;
   let fpSqrt64     <- Float64::mkFpSqrt64;
   let fpExp64      <- Float64::mkFpExp64;
   let fpFma64      <- Float64::mkFpFma64;
   let fpSqrtCube64 <- Float64::mkFpSqrtCube64;

   Reg#(Bit#(32)) addObs32      <- mkReg(0);
   Reg#(Bit#(32)) subObs32      <- mkReg(0);
   Reg#(Bit#(32)) multObs32     <- mkReg(0);
   Reg#(Bit#(32)) divObs32      <- mkReg(0);
   Reg#(Bit#(32)) sqrtObs32     <- mkReg(0);
   Reg#(Bit#(32)) expObs32      <- mkReg(0);
   Reg#(Bit#(32)) fmaObs32      <- mkReg(0);
   Reg#(Bit#(32)) sqrtCubeObs32 <- mkReg(0);

   Reg#(Bit#(64)) addObs64      <- mkReg(0);
   Reg#(Bit#(64)) subObs64      <- mkReg(0);
   Reg#(Bit#(64)) multObs64     <- mkReg(0);
   Reg#(Bit#(64)) divObs64      <- mkReg(0);
   Reg#(Bit#(64)) sqrtObs64     <- mkReg(0);
   Reg#(Bit#(64)) expObs64      <- mkReg(0);
   Reg#(Bit#(64)) fmaObs64      <- mkReg(0);
   Reg#(Bit#(64)) sqrtCubeObs64 <- mkReg(0);

   Reg#(Bit#(16)) passMask <- mkReg(0);

   // --------------------------------------------------------------------------
   // System start
   // --------------------------------------------------------------------------
   rule systemStart (!started);
      startQ.deq;
      started        <= True;
      state          <= ST_REQ_INPUT0;
      cycleStart     <= cycleCounter;

      inputWord0     <= 0;
      inputWord1     <= 0;
      inputWord2     <= 0;
      resultWord0    <= 0;
      resultWord1    <= 0;
      resultWord2    <= 0;

      hostPathPass32 <= False;
      hostPathPass64 <= False;

      addObs32       <= 0;
      subObs32       <= 0;
      multObs32      <= 0;
      divObs32       <= 0;
      sqrtObs32      <= 0;
      expObs32       <= 0;
      fmaObs32       <= 0;
      sqrtCubeObs32  <= 0;

      addObs64       <= 0;
      subObs64       <= 0;
      multObs64      <= 0;
      divObs64       <= 0;
      sqrtObs64      <= 0;
      expObs64       <= 0;
      fmaObs64       <= 0;
      sqrtCubeObs64  <= 0;

      passMask       <= 0;
   endrule

   // --------------------------------------------------------------------------
   // Read three 512-bit input beats from the direct host connection and stage
   // them through URAM before running any tests.
   // --------------------------------------------------------------------------
   rule reqInput0 (started && state == ST_REQ_INPUT0);
      readReqQs[0].enq(MemPortReq{addr: 64'd0, bytes: 32'd64});
      state <= ST_RECV_INPUT0;
   endrule

   rule recvInput0 (started && state == ST_RECV_INPUT0);
      let w = readWordQs[0].first;
      readWordQs[0].deq;
      inputWord0 <= w;
      uramIn.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 0, datain: w}
      );
      state <= ST_REQ_INPUT1;
   endrule

   rule reqInput1 (started && state == ST_REQ_INPUT1);
      readReqQs[0].enq(MemPortReq{addr: 64'd64, bytes: 32'd64});
      state <= ST_RECV_INPUT1;
   endrule

   rule recvInput1 (started && state == ST_RECV_INPUT1);
      let w = readWordQs[0].first;
      readWordQs[0].deq;
      inputWord1 <= w;
      uramIn.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 1, datain: w}
      );
      state <= ST_REQ_INPUT2;
   endrule

   rule reqInput2 (started && state == ST_REQ_INPUT2);
      readReqQs[0].enq(MemPortReq{addr: 64'd128, bytes: 32'd64});
      state <= ST_RECV_INPUT2;
   endrule

   rule recvInput2 (started && state == ST_RECV_INPUT2);
      let w = readWordQs[0].first;
      readWordQs[0].deq;
      inputWord2 <= w;
      uramIn.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 2, datain: w}
      );
      state <= ST_REQ_URAM_IN0;
   endrule

   rule reqReadUramIn0 (started && state == ST_REQ_URAM_IN0);
      uramIn.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 0, datain: ?}
      );
      state <= ST_RECV_URAM_IN0;
   endrule

   rule recvReadUramIn0 (started && state == ST_RECV_URAM_IN0);
      let w <- uramIn.portB.response.get;
      inputWord0 <= w;
      hostPathPass32 <= (w[479:448] == kInputMagic0) && (w[511:480] == kInputMagic1);
      state <= ST_REQ_URAM_IN1;
   endrule

   rule reqReadUramIn1 (started && state == ST_REQ_URAM_IN1);
      uramIn.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 1, datain: ?}
      );
      state <= ST_RECV_URAM_IN1;
   endrule

   rule recvReadUramIn1 (started && state == ST_RECV_URAM_IN1);
      let w <- uramIn.portB.response.get;
      inputWord1 <= w;
      state <= ST_REQ_URAM_IN2;
   endrule

   rule reqReadUramIn2 (started && state == ST_REQ_URAM_IN2);
      uramIn.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 2, datain: ?}
      );
      state <= ST_RECV_URAM_IN2;
   endrule

   rule recvReadUramIn2 (started && state == ST_RECV_URAM_IN2);
      let w <- uramIn.portB.response.get;
      inputWord2 <= w;
      hostPathPass64 <= (w[447:384] == kInputMagic64_0) && (w[511:448] == kInputMagic64_1);
      state <= ST_ADD32_ENQ;
   endrule

   // --------------------------------------------------------------------------
   // 32-bit Float tests (beat 0)
   // --------------------------------------------------------------------------
   rule doAdd32Enq (started && state == ST_ADD32_ENQ);
      fpAdd32.enq(inputWord0[31:0], inputWord0[63:32]);
      state <= ST_ADD32_GET;
   endrule

   rule doAdd32Get (started && state == ST_ADD32_GET);
      let v = fpAdd32.first;
      fpAdd32.deq;
      addObs32 <= v;
      if (v == kAddExpected32) passMask <= passMask | 16'h0001;
      state <= ST_SUB32_ENQ;
   endrule

   rule doSub32Enq (started && state == ST_SUB32_ENQ);
      fpSub32.enq(inputWord0[95:64], inputWord0[127:96]);
      state <= ST_SUB32_GET;
   endrule

   rule doSub32Get (started && state == ST_SUB32_GET);
      let v = fpSub32.first;
      fpSub32.deq;
      subObs32 <= v;
      if (v == kSubExpected32) passMask <= passMask | 16'h0002;
      state <= ST_MUL32_ENQ;
   endrule

   rule doMul32Enq (started && state == ST_MUL32_ENQ);
      fpMult32.enq(inputWord0[159:128], inputWord0[191:160]);
      state <= ST_MUL32_GET;
   endrule

   rule doMul32Get (started && state == ST_MUL32_GET);
      let v = fpMult32.first;
      fpMult32.deq;
      multObs32 <= v;
      if (v == kMulExpected32) passMask <= passMask | 16'h0004;
      state <= ST_DIV32_ENQ;
   endrule

   rule doDiv32Enq (started && state == ST_DIV32_ENQ);
      fpDiv32.enq(inputWord0[223:192], inputWord0[255:224]);
      state <= ST_DIV32_GET;
   endrule

   rule doDiv32Get (started && state == ST_DIV32_GET);
      let v = fpDiv32.first;
      fpDiv32.deq;
      divObs32 <= v;
      if (v == kDivExpected32) passMask <= passMask | 16'h0008;
      state <= ST_SQRT32_ENQ;
   endrule

   rule doSqrt32Enq (started && state == ST_SQRT32_ENQ);
      fpSqrt32.enq(inputWord0[287:256]);
      state <= ST_SQRT32_GET;
   endrule

   rule doSqrt32Get (started && state == ST_SQRT32_GET);
      let v = fpSqrt32.first;
      fpSqrt32.deq;
      sqrtObs32 <= v;
      if (v == kSqrtExpected32) passMask <= passMask | 16'h0010;
      state <= ST_EXP32_ENQ;
   endrule

   rule doExp32Enq (started && state == ST_EXP32_ENQ);
      fpExp32.enq(inputWord0[319:288]);
      state <= ST_EXP32_GET;
   endrule

   rule doExp32Get (started && state == ST_EXP32_GET);
      let v = fpExp32.first;
      fpExp32.deq;
      expObs32 <= v;
      if (v == kExpExpected32) passMask <= passMask | 16'h0020;
      state <= ST_FMA32_ENQ;
   endrule

   rule doFma32Enq (started && state == ST_FMA32_ENQ);
      fpFma32.enq(inputWord0[351:320], inputWord0[383:352], inputWord0[415:384], True);
      state <= ST_FMA32_GET;
   endrule

   rule doFma32Get (started && state == ST_FMA32_GET);
      let v = fpFma32.first;
      fpFma32.deq;
      fmaObs32 <= v;
      if (v == kFmaExpected32) passMask <= passMask | 16'h0040;
      state <= ST_SQRTCUBE32_ENQ;
   endrule

   rule doSqrtCube32Enq (started && state == ST_SQRTCUBE32_ENQ);
      fpSqrtCube32.enq(inputWord0[447:416]);
      state <= ST_SQRTCUBE32_GET;
   endrule

   rule doSqrtCube32Get (started && state == ST_SQRTCUBE32_GET);
      let v = fpSqrtCube32.first;
      fpSqrtCube32.deq;
      sqrtCubeObs32 <= v;
      if (v == kScubeExpected32) passMask <= passMask | 16'h0080;
      state <= ST_ADD64_ENQ;
   endrule

   // --------------------------------------------------------------------------
   // 64-bit Float tests (beats 1 and 2)
   // Beat 1 lanes: add_a, add_b, sub_a, sub_b, mul_a, mul_b, div_a, div_b
   // Beat 2 lanes: sqrt_a, exp_a, fma_a, fma_b, fma_c, sqrtcube_a, magic64_0,
   //               magic64_1
   // --------------------------------------------------------------------------
   rule doAdd64Enq (started && state == ST_ADD64_ENQ);
      fpAdd64.enq(inputWord1[63:0], inputWord1[127:64]);
      state <= ST_ADD64_GET;
   endrule

   rule doAdd64Get (started && state == ST_ADD64_GET);
      let v = fpAdd64.first;
      fpAdd64.deq;
      addObs64 <= v;
      if (v == kAddExpected64) passMask <= passMask | 16'h0100;
      state <= ST_SUB64_ENQ;
   endrule

   rule doSub64Enq (started && state == ST_SUB64_ENQ);
      fpSub64.enq(inputWord1[191:128], inputWord1[255:192]);
      state <= ST_SUB64_GET;
   endrule

   rule doSub64Get (started && state == ST_SUB64_GET);
      let v = fpSub64.first;
      fpSub64.deq;
      subObs64 <= v;
      if (v == kSubExpected64) passMask <= passMask | 16'h0200;
      state <= ST_MUL64_ENQ;
   endrule

   rule doMul64Enq (started && state == ST_MUL64_ENQ);
      fpMult64.enq(inputWord1[319:256], inputWord1[383:320]);
      state <= ST_MUL64_GET;
   endrule

   rule doMul64Get (started && state == ST_MUL64_GET);
      let v = fpMult64.first;
      fpMult64.deq;
      multObs64 <= v;
      if (v == kMulExpected64) passMask <= passMask | 16'h0400;
      state <= ST_DIV64_ENQ;
   endrule

   rule doDiv64Enq (started && state == ST_DIV64_ENQ);
      fpDiv64.enq(inputWord1[447:384], inputWord1[511:448]);
      state <= ST_DIV64_GET;
   endrule

   rule doDiv64Get (started && state == ST_DIV64_GET);
      let v = fpDiv64.first;
      fpDiv64.deq;
      divObs64 <= v;
      if (v == kDivExpected64) passMask <= passMask | 16'h0800;
      state <= ST_SQRT64_ENQ;
   endrule

   rule doSqrt64Enq (started && state == ST_SQRT64_ENQ);
      fpSqrt64.enq(inputWord2[63:0]);
      state <= ST_SQRT64_GET;
   endrule

   rule doSqrt64Get (started && state == ST_SQRT64_GET);
      let v = fpSqrt64.first;
      fpSqrt64.deq;
      sqrtObs64 <= v;
      if (v == kSqrtExpected64) passMask <= passMask | 16'h1000;
      state <= ST_EXP64_ENQ;
   endrule

   rule doExp64Enq (started && state == ST_EXP64_ENQ);
      fpExp64.enq(inputWord2[127:64]);
      state <= ST_EXP64_GET;
   endrule

   rule doExp64Get (started && state == ST_EXP64_GET);
      let v = fpExp64.first;
      fpExp64.deq;
      expObs64 <= v;
      if (v == kExpExpected64) passMask <= passMask | 16'h2000;
      state <= ST_FMA64_ENQ;
   endrule

   rule doFma64Enq (started && state == ST_FMA64_ENQ);
      fpFma64.enq(inputWord2[191:128], inputWord2[255:192], inputWord2[319:256], True);
      state <= ST_FMA64_GET;
   endrule

   rule doFma64Get (started && state == ST_FMA64_GET);
      let v = fpFma64.first;
      fpFma64.deq;
      fmaObs64 <= v;
      if (v == kFmaExpected64) passMask <= passMask | 16'h4000;
      state <= ST_SQRTCUBE64_ENQ;
   endrule

   rule doSqrtCube64Enq (started && state == ST_SQRTCUBE64_ENQ);
      fpSqrtCube64.enq(inputWord2[383:320]);
      state <= ST_SQRTCUBE64_GET;
   endrule

   rule doSqrtCube64Get (started && state == ST_SQRTCUBE64_GET);
      let v = fpSqrtCube64.first;
      fpSqrtCube64.deq;
      sqrtCubeObs64 <= v;
      if (v == kScubeExpected64) passMask <= passMask | 16'h8000;
      state <= ST_PACK_RESULT;
   endrule

   // --------------------------------------------------------------------------
   // Pack the result into three 512-bit beats.
   // Beat 0: summary + Float32 observations
   // Beat 1: Float64 observations
   // Beat 2: echoed 64-bit sentinels (after URAM path)
   // --------------------------------------------------------------------------
   rule packResult (started && state == ST_PACK_RESULT);
      Bit#(32) hostPass32 = zeroExtend(pack(hostPathPass32));
      Bit#(32) hostPass64 = zeroExtend(pack(hostPathPass64));
      Bit#(32) status     = (hostPathPass32 && hostPathPass64 && (passMask == 16'hFFFF))
                              ? 32'd3
                              : (32'hBAD00000 | zeroExtend(passMask));
      Bit#(32) cycles     = cycleCounter - cycleStart;

      resultWord0 <= {
         hostPass64,          // lane 15
         hostPass32,          // lane 14
         inputWord0[511:480], // lane 13, echoed 32-bit sentinel 1
         inputWord0[479:448], // lane 12, echoed 32-bit sentinel 0
         sqrtCubeObs32,       // lane 11
         fmaObs32,            // lane 10
         expObs32,            // lane  9
         sqrtObs32,           // lane  8
         divObs32,            // lane  7
         multObs32,           // lane  6
         subObs32,            // lane  5
         addObs32,            // lane  4
         cycles,              // lane  3
         zeroExtend(passMask),// lane  2
         status,              // lane  1
         kMagic32             // lane  0
      };

      resultWord1 <= {
         sqrtCubeObs64,
         fmaObs64,
         expObs64,
         sqrtObs64,
         divObs64,
         multObs64,
         subObs64,
         addObs64
      };

      resultWord2 <= {
         64'h0,
         64'h0,
         64'h0,
         64'h0,
         64'h0,
         64'h0,
         inputWord2[511:448], // lane 7 echoed 64-bit sentinel 1
         inputWord2[447:384]  // lane 6 echoed 64-bit sentinel 0
      };

      state <= ST_STORE_RESULT0_URAM;
   endrule

   rule storeResult0Uram (started && state == ST_STORE_RESULT0_URAM);
      uramOut.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 0, datain: resultWord0}
      );
      state <= ST_STORE_RESULT1_URAM;
   endrule

   rule storeResult1Uram (started && state == ST_STORE_RESULT1_URAM);
      uramOut.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 1, datain: resultWord1}
      );
      state <= ST_STORE_RESULT2_URAM;
   endrule

   rule storeResult2Uram (started && state == ST_STORE_RESULT2_URAM);
      uramOut.portA.request.put(
         URAMRequest{write: True, responseOnWrite: False, address: 2, datain: resultWord2}
      );
      state <= ST_REQ_URAM_OUT0;
   endrule

   rule reqReadUramOut0 (started && state == ST_REQ_URAM_OUT0);
      uramOut.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 0, datain: ?}
      );
      state <= ST_RECV_URAM_OUT0;
   endrule

   rule recvReadUramOut0 (started && state == ST_RECV_URAM_OUT0);
      let w <- uramOut.portB.response.get;
      resultWord0 <= w;
      state <= ST_REQ_URAM_OUT1;
   endrule

   rule reqReadUramOut1 (started && state == ST_REQ_URAM_OUT1);
      uramOut.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 1, datain: ?}
      );
      state <= ST_RECV_URAM_OUT1;
   endrule

   rule recvReadUramOut1 (started && state == ST_RECV_URAM_OUT1);
      let w <- uramOut.portB.response.get;
      resultWord1 <= w;
      state <= ST_REQ_URAM_OUT2;
   endrule

   rule reqReadUramOut2 (started && state == ST_REQ_URAM_OUT2);
      uramOut.portB.request.put(
         URAMRequest{write: False, responseOnWrite: False, address: 2, datain: ?}
      );
      state <= ST_RECV_URAM_OUT2;
   endrule

   rule recvReadUramOut2 (started && state == ST_RECV_URAM_OUT2);
      let w <- uramOut.portB.response.get;
      resultWord2 <= w;
      state <= ST_REQ_WRITE0;
   endrule

   rule reqWriteResult0 (started && state == ST_REQ_WRITE0);
      writeReqQs[1].enq(MemPortReq{addr: 64'd0, bytes: 32'd64});
      state <= ST_WRITE_WORD0;
   endrule

   rule writeResult0 (started && state == ST_WRITE_WORD0);
      writeWordQs[1].enq(resultWord0);
      state <= ST_REQ_WRITE1;
   endrule

   rule reqWriteResult1 (started && state == ST_REQ_WRITE1);
      writeReqQs[1].enq(MemPortReq{addr: 64'd64, bytes: 32'd64});
      state <= ST_WRITE_WORD1;
   endrule

   rule writeResult1 (started && state == ST_WRITE_WORD1);
      writeWordQs[1].enq(resultWord1);
      state <= ST_REQ_WRITE2;
   endrule

   rule reqWriteResult2 (started && state == ST_REQ_WRITE2);
      writeReqQs[1].enq(MemPortReq{addr: 64'd128, bytes: 32'd64});
      state <= ST_WRITE_WORD2;
   endrule

   rule writeResult2 (started && state == ST_WRITE_WORD2);
      writeWordQs[1].enq(resultWord2);
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
