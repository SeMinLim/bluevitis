.PHONY: all model protocol test clean

CXX := g++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -pedantic
COMMON_SOURCES := Utility.cpp SeedInitialization.cpp AcceleratorMath.cpp AcceleratorProtocol.cpp AcceleratorModel.cpp HostOrchestrator.cpp Application.cpp Result.cpp
HEADERS := MorbiusPlus.h

all: obj/main

obj/main: main.cpp $(COMMON_SOURCES) $(HEADERS)
	mkdir -p obj/
	$(CXX) $(CXXFLAGS) main.cpp $(COMMON_SOURCES) -o obj/main \
		-I$(XILINX_XRT)/include/ -L$(XILINX_XRT)/lib -lxrt_coreutil -pthread

model: obj/model

obj/model: main_model.cpp $(COMMON_SOURCES) $(HEADERS)
	mkdir -p obj/
	$(CXX) $(CXXFLAGS) main_model.cpp $(COMMON_SOURCES) -o obj/model -pthread

protocol: obj/test_protocol
	./obj/test_protocol

obj/test_protocol: test/test_protocol.cpp AcceleratorMath.cpp AcceleratorProtocol.cpp AcceleratorModel.cpp Utility.cpp $(HEADERS)
	mkdir -p obj/
	$(CXX) $(CXXFLAGS) test/test_protocol.cpp AcceleratorMath.cpp AcceleratorProtocol.cpp AcceleratorModel.cpp Utility.cpp \
		-o obj/test_protocol

test: model protocol
	bash test/run_accel_test.sh

clean:
	rm -rf obj/ test/output test/output_dataset
	rm -rf *.log emconfig.json
