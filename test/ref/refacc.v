// An accumulator as someone else would write it, for co-simulation against the
// QuartzHDL module of the same name. Its register powers up undefined, as a real
// design's does, so the testbench has to put it in the state the Julia model starts in.
module RefAcc (
  input wire clk_i,
  input wire [7:0] d_i,
  input wire rst_i,
  output wire [7:0] y_o
);
  reg [7:0] acc;
  reg [7:0] y;
  always @(posedge clk_i) begin
    if (rst_i) begin
      acc <= 8'd5;
      y <= 8'd0;
    end else begin
      acc <= acc + d_i;
      y <= acc;
    end
  end
  assign y_o = y;
endmodule
