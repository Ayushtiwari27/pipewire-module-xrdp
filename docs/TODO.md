# Implementation TODO

## Phase 1: Code Cleanup
- [ ] Remove xrdp socket defines
- [ ] Remove PA_CMD_* protocol
- [ ] Remove socket connection functions
- [ ] Remove xrdp protocol structures
- [ ] Compile check

## Phase 2: FIFO Infrastructure
- [ ] Add FIFO path defines
- [ ] Implement open_speaker_fifo()
- [ ] Implement open_mic_fifo()
- [ ] Implement close_fifos()
- [ ] Compile check

## Phase 3: Stream Callbacks
- [ ] Modify on_sink_process()
- [ ] Modify on_source_process()
- [ ] Add error handling
- [ ] Add reconnection logic
- [ ] Compile and basic test

## Phase 4: Format Negotiation
- [ ] Add param_changed callbacks
- [ ] Implement write_format_spec()
- [ ] Expand format enumeration
- [ ] Test format changes

## Phase 5: Scripts & Testing
- [ ] Create ffmpeg_manager.sh
- [ ] Create test scripts
- [ ] Integration testing
- [ ] Documentation

## Current Status
Working on: _____
Last compiled: _____
Last tested: _____
