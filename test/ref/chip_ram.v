// Behavioural model of the CHIP_RAM black box, for co-simulation under iverilog:
// a 256 x 8 memory with a read port and a write port on their own clocks. A read
// of the address being written sees the old byte, as the vendor block does.
`timescale 1ns/1ns
module CHIP_RAM (WrAddress, RdAddress, Data, WE, RdClock, WrClock, Q);
  input wire [7:0] WrAddress, RdAddress, Data;
  input wire WE, RdClock, WrClock;
  output reg [7:0] Q = 8'd0;
  reg [7:0] mem [0:255];
  integer i;
  initial for (i = 0; i < 256; i = i + 1) mem[i] = 8'd0;
  always @(posedge WrClock) if (WE) mem[WrAddress] <= Data;
  always @(posedge RdClock) Q <= mem[RdAddress];
endmodule
