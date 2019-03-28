#!/bin/bash
# shellcheck disable=SC2031
source ./lib.bash
source ./lib-matrix-files.bash

# Regression tests for past matrix failures.
# The full matrix test is too slow to run as a normal part of the test suite;
# they can be run manually from the ./m-*.sh scripts.

TestPhase_Setup ###############################################################

tests=(
	00-1111-1222-1311
)
TestMatrixFileSetup "${tests[@]}"
unset tests

TestPhase_Run #################################################################
AconfSave
AconfApply

TestPhase_Check ###############################################################
TestMatrixFileCheckRoundtrip

TestDone ######################################################################