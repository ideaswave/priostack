# Priostack ACN — C++ client build.
#
# The client itself is header-only (include/priostack/priostack.hpp); nothing
# to compile to use it. This Makefile just builds the quickstart example.
#
#   make            # build ./quickstart
#   make run        # build and run it against the live ACN
#   make clean

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
INCLUDES  = -Iinclude
LDLIBS    = -lcurl

quickstart: examples/quickstart.cpp include/priostack/priostack.hpp
	$(CXX) $(CXXFLAGS) $(INCLUDES) examples/quickstart.cpp $(LDLIBS) -o quickstart

.PHONY: run clean
run: quickstart
	./quickstart

clean:
	rm -f quickstart
