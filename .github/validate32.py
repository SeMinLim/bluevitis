from pathlib import Path
import os
import random
import re
import subprocess

repo = Path.cwd()
root = repo / 'hw/kernel_morbius_plus'
host = repo / 'sw/host_morbius_plus'
work = Path('/tmp/morbius32-validation')
work.mkdir(exist_ok=True)
logs = work / 'logs'
logs.mkdir(exist_ok=True)
bsc_home = Path(os.environ['BSC_HOME'])
unisim = Path('/tmp/unisim/verilog/src')
passed = []

def run(name, args, cwd=None, timeout=1200, marker=None):
    print('RUN ' + name, flush=True)
    try:
        p = subprocess.run([str(x) for x in args], cwd=cwd or root,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        text = e.stdout or b''
        if isinstance(text, bytes):
            text = text.decode(errors='replace')
        (logs / (name + '.log')).write_text(text)
        raise
    (logs / (name + '.log')).write_text(p.stdout)
    print(p.stdout[-5000:], flush=True)
    if p.returncode != 0 or re.search(r'FAIL[: ]|FATAL:', p.stdout):
        raise RuntimeError(name + ' failed')
    if marker is not None and marker not in p.stdout:
        raise RuntimeError(name + ' missing marker: ' + marker)
    return p.stdout

def compile_bsv(name, source, top, extra_paths=()):
    out = work / name
    out.mkdir(exist_ok=True)
    search = '+:' + str(root) + ':' + str(root / 'test')
    for path in extra_paths:
        search += ':' + str(path)
    text = run(name, ['bsc', '+RTS', '-K512M', '-RTS', '-steps', '10000000',
        '-show-schedule', '-aggressive-conditions', '-p', search,
        '-bdir', out, '-vdir', out, '-simdir', out, '-info-dir', out,
        '-verilog', '-u', '-g', top, source])
    if re.search(r'^(Error|Warning):', text, re.M):
        raise RuntimeError(name + ' has BSC diagnostics')
    return out

def compile_rtl(name, top, files, wrapper=False):
    inputs = list(files)
    if wrapper:
        tb = work / (name + '_tb.v')
        tb.write_text('module tb; reg CLK=0; always #5 CLK=~CLK; reg RST_N=0; '
                      'initial begin #200; @(negedge CLK); RST_N=1; end '
                      + top + ' dut(.CLK(CLK),.RST_N(RST_N)); endmodule\n')
        inputs.append(tb)
        top = 'tb'
    exe = work / (name + '.vvp')
    run(name + '-iverilog', ['iverilog', '-g2012', '-s', top, '-s', 'glbl',
        '-y', bsc_home / 'lib/Verilog', '-y', unisim / 'unisims',
        '-o', exe, *inputs, unisim / 'glbl.v'])
    return exe

assert 'typedef 32 NumPE_Profiler;' in (root / 'MorbiusTypes.bsv').read_text()
assert 'typedef 16 NumPipeline;' in (root / 'MorbiusTypes.bsv').read_text()
assert 'typedef 4 NumPE_LPM;' in (root / 'MorbiusTypes.bsv').read_text()
assert '#define ACCELSEGMENTSIZE 32' in (host / 'MorbiusPlus.h').read_text()

# Complete production elaboration uses actual native primitive definitions.
kernel = compile_bsv('kernel', root / 'KernelTop.bsv', 'kernel')
compile_rtl('kernel-native', 'kernel', list(kernel.glob('*.v')) + list(root.glob('*.v')))
passed.append('Complete 32/32 kernel BSC elaboration without warnings and native RTL elaboration')

primitive = compile_rtl('native-primitives', 'TestResourcePrimitives',
    [root / 'MorbiusProfilerAdd.v', root / 'MorbiusLpmRam.v',
     root / 'test/MorbiusNativeModels.sv', root / 'test/TestResourcePrimitives.sv'])
run('native-primitives-run', ['vvp', primitive], marker='PASS:')
passed.append('Unchanged native DSP and masked RAM cycle contracts')

# Long traces use the explicitly test-only models after the native comparison.
models = work / 'NativeModels.v'
text = (root / 'test/MorbiusNativeModels.sv').read_text()
text = text.replace('MorbiusProfilerAddModel', 'MorbiusProfilerAdd')
text = text.replace('MorbiusLpmRamModel', 'MorbiusLpmRam')
models.write_text(text)
sim_native = [models, root / 'MorbiusSdpRam.v']

for name, source, top in [
    ('profiler32', 'TestProfiler32.bsv', 'mkTestProfiler32'),
    ('sequence32', 'TestSequenceMemory32.bsv', 'mkTestSequenceMemory32'),
]:
    out = compile_bsv(name, root / 'test' / source, top)
    exe = compile_rtl(name, top, list(out.glob('*.v')) + sim_native, wrapper=True)
    text = run(name + '-run', ['vvp', exe], marker='PASS:')
    passed.append(text.strip())

# Independently check all 32 PWL lanes against the host arithmetic functions.
# Requests are generated in C++; the BSV checker compares every result bit.
pwl_dir = work / 'pwl-vectors'
pwl_dir.mkdir(exist_ok=True)
(pwl_dir / 'generate.cpp').write_text(r'''#include "MorbiusPlus.h"
#include <cstdio>
#include <cstdint>
int main() {
    FILE *req = fopen("pwl-input.hex", "w");
    FILE *exp = fopen("pwl-expected.hex", "w");
    if ( !req || !exp ) return 1;
    for ( uint32_t n = 0; n < 36896; n ++ ) {
        bool logMode = n < 32768;
        uint32_t val[32] = {}, expected[32] = {};
        for ( uint32_t i = 0; i < 32; i ++ ) {
            if ( logMode ) val[i] = n * 8 + (i % 8);
            else if ( n < 36864 ) val[i] = (n - 32768) * 32 + i;
            else val[i] = 0xffffffU - i;
            expected[i] = logMode ? (i < 8 ? calculateLog2PWLQ12(val[i]) : 0)
                                      : calculateExp2PWLQ18(val[i]);
        }
        // 1 mode bit followed by 32 x 24 input bits.
        fprintf(req, "%01x", logMode ? 0 : 1);
        for ( int i = 31; i >= 0; i -- ) fprintf(req, "%06x", val[i]);
        fprintf(req, "\n");
        // Store output in 32-bit words for independent packing.
        for ( int i = 31; i >= 0; i -- ) fprintf(exp, "%08x", expected[i]);
        fprintf(exp, "\n");
    }
    return (fclose(req) != 0 || fclose(exp) != 0) ? 1 : 0;
}
''')
run('pwl-generate-build', ['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-O2',
    '-I', host, pwl_dir / 'generate.cpp', host / 'AcceleratorMath.cpp',
    host / 'Utility.cpp', '-o', pwl_dir / 'generate'])
run('pwl-generate', [pwl_dir / 'generate'], cwd=pwl_dir)
(pwl_dir / 'TestPwl32.bsv').write_text('''package TestPwl32;
import Vector::*;
import RegFile::*;
import MorbiusTypes::*;
import PwlLane::*;
(* synthesize *)
module mkTestPwl32(Empty);
    PwlArrayIfc dut <- mkPwlArray;
    RegFile#(Bit#(16), Bit#(769)) inputs <- mkRegFileLoad("pwl-input.hex", 0, 36895);
    RegFile#(Bit#(16), Bit#(1024)) expected <- mkRegFileLoad("pwl-expected.hex", 0, 36895);
    Reg#(Bit#(16)) sentR <- mkReg(0);
    Reg#(Bit#(16)) receivedR <- mkReg(0);
    Reg#(UInt#(32)) cyclesR <- mkReg(0);
    rule tick;
        cyclesR <= cyclesR + 1;
        if ( cyclesR == 200000 ) begin $display("FAIL: PWL timeout"); $finish(1); end
    endrule
    rule send1 ( sentR < 36896 && cyclesR % 11 != 5 );
        Bit#(769) inputWord = inputs.sub(sentR);
        PwlArrayRequest request = PwlArrayRequest{mode: inputWord[768] == 0 ? PWL_LOG2 : PWL_EXP2,
                                                value: replicate(0), validMask: '1};
        for ( Integer i = 0; i < 32; i = i + 1 ) begin
            request.value[i] = unpack(inputWord[i * 24 + 23:i * 24]);
        end
        dut.put(request);
        sentR <= sentR + 1;
    endrule
    rule check1 ( receivedR < 36896 && cyclesR % 7 != 3 );
        let actual <- dut.get;
        Bit#(1024) expectedWord = expected.sub(receivedR);
        for ( Integer i = 0; i < 32; i = i + 1 ) begin
            Bit#(32) actualValue = zeroExtend(pack(actual.value[i]));
            Bit#(32) expectedValue = expectedWord[i * 32 + 31:i * 32];
            if ( actualValue != expectedValue ) begin
                $display("FAIL: PWL request=%0d lane=%0d got=%0d expected=%0d", receivedR, i, actualValue, expectedValue);
                $finish(1);
            end
        end
        receivedR <= receivedR + 1;
        if ( receivedR == 36895 ) begin
            $display("PASS: 36896 PWL vectors, 32 lanes, all 18-bit counts, 131072 exp inputs and stalls");
            $finish(0);
        end
    endrule
endmodule
endpackage
''')
pwl = compile_bsv('pwl32', pwl_dir / 'TestPwl32.bsv', 'mkTestPwl32', [pwl_dir])
pwl_exe = compile_rtl('pwl32', 'mkTestPwl32', list(pwl.glob('*.v')), wrapper=True)
run('pwl32-run', ['vvp', pwl_exe], cwd=pwl_dir, marker='PASS:')
passed.append('32-lane PWL arithmetic bit-for-bit against independent C++ oracle with input/output stalls')

common = ['Utility.cpp', 'SeedInitialization.cpp', 'AcceleratorMath.cpp', 'AcceleratorProtocol.cpp',
          'AcceleratorModel.cpp', 'HostOrchestrator.cpp', 'Application.cpp', 'Result.cpp']
trace_exe = work / 'trace-model'
run('trace-model-build', ['g++', '-std=c++17', '-Wall', '-Wextra', '-pedantic', '-Werror', '-O2',
    '-pthread', '-I', host, root / 'test/TraceExecutor.cpp', *[host / x for x in common], '-o', trace_exe])
trace = compile_bsv('trace32', root / 'test/TestKernelTrace.bsv', 'mkTestKernelTrace')
trace_sim = compile_rtl('trace32', 'mkTestKernelTrace', list(trace.glob('*.v')) + sim_native, wrapper=True)
rng = random.Random(1729)
cases = [
    ('dna-test', 0, 64, 16, 'dna', 96, 32, 1.0),
    ('dna-full32', 16, 47, 16, 'dna', 8, 3, 1.0),
    ('dna-tail1', 16, 48, 16, 'dna', 8, 3, 1.0),
    ('dna-tail31', 16, 78, 16, 'dna', 8, 3, 1.0),
    ('dna-beat-tail', 16, 65, 15, 'dna', 8, 3, 1.0),
    ('dna-single', 16, 16, 16, 'dna', 4, 2, 1.0),
    ('dna-maximum', 16, 1024, 128, 'dna', 2, 1, 1.0),
    ('dna-minimum-motif', 16, 64, 4, 'dna', 6, 2, 1.0),
    ('protein', 16, 300, 16, 'protein', 10, 3, 1.0),
    ('protein-tail', 16, 129, 127, 'protein', 4, 2, 1.0),
    ('terminated', 16, 64, 4, 'dna', 4, 2, 0.1),
]
for name, count, length, width, alphabet, updates, batch, threshold in cases:
    case = work / name
    case.mkdir(exist_ok=True)
    if count == 0:
        fasta = host / 'test/DNA_TEST.fasta'
    else:
        letters = 'ACGT' if alphabet == 'dna' else 'ACDEFGHIKLMNPQRSTVWY'
        fasta = case / 'input.fa'
        with fasta.open('w') as f:
            for i in range(count):
                f.write('>seq' + str(i) + '\n' + ''.join(rng.choice(letters) for _ in range(length)) + '\n')
    run(name + '-oracle', [trace_exe, '--model', '--input', fasta, '--output', case / 'result',
        '--alphabet', alphabet, '--motif-length', width, '--max-updates', updates,
        '--score-threshold', threshold, '--seed', 1, '--batch-size', batch], cwd=case)
    for name_hex, limit in [('input.hex', 65536), ('expected.hex', 65536), ('commands.hex', 256)]:
        assert len((case / name_hex).read_text().splitlines()) <= limit
    text = run(name + '-rtl', ['vvp', trace_sim], cwd=case, timeout=1200, marker='PASS: kernel')
    passed.append(name + ': ' + next(line for line in text.splitlines() if line.startswith('PASS: kernel')))

text = run('bluesim', ['make', 'sim'], timeout=1200, marker='bootstrap and update test passed')
if re.search(r'^Error:|can never fire|will never fire|has no effect', text, re.M):
    raise RuntimeError('Bluesim scheduling failure')
passed.append('Existing complete Gibbs Bluesim bootstrap and update test')
run('host-tests', ['make', '-C', host, 'test', 'CXXFLAGS=-std=c++17 -Wall -Wextra -pedantic -Werror -O2'])
passed.append('Host model and protocol tests with warnings as errors')
summary = '\n'.join('PASS ' + item for item in passed) + '\n'
(logs / 'SUMMARY.txt').write_text(summary)
print(summary, flush=True)
