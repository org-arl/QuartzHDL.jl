# the library's components, each against a small design or each other

using Test, QuartzHDL, QuartzHDL.Units

@quartz struct Loop
  @in rx::Bool = true
  @out tx::Bool = true
end

@on Loop posedge(clk) begin
  tx ← rx
end

@testset "UART: bytes out, bytes back, frames and closures" begin
  sim = Simulation(Loop(); clocks = (@clocks begin clk = 48MHz end))
  u = UART(sim; rx = "tx", tx = "rx", baud = 115200, parity = :even, timeout = 10ms)
  @test write(u, "Hi!") == 3 && abs(time(sim) - 33 / 115200) < 2 / 48e6
  @test String(read(u, 3)) == "Hi!"
  put!(u, [0x55, 0xaa])
  @run sim advance_by(300us)
  @test take!(u) == [0x55, 0xaa] && bytesavailable(u) == 0
  seen = UInt8[]
  on(u) do b; append!(seen, b); nothing; end
  @run sim begin put!(u, [1, 2]); advance_by(300us) end
  @test seen == [1, 2] && isempty(take!(u))
  on(nothing, u)
  w = UART(sim; rx = "tx", frame = "\n", parity = :even, timeout = 10ms)
  write(u, "line one\nline two\n")
  @test String(take!(w)) == "line one\n" && String(read(w)) == "line two\n" && !isready(w)
  # nothing comes, so the timeout fires, and it says what was waited for
  @test_throws "timed out after 10.0ms waiting to read" read(w, 1)
  close(u); close(w)
  @test !isopen(u) && isempty(sim.tasks)
end

@quartz struct Fifo
  @in rxf::Bool
  @in txe::Bool
  @io data::Pad{8} = Pad{8}()
  @out rd::Bool = false
  @out wr::Bool = false
  @in go::Bool = false
  got::Bits{8} = 0
  n::Bits{4} = 0
end

# reads a byte whenever one is offered, and writes it back doubled
@on Fifo posedge(clk) begin
  if rd
    got ← data
    rd ← false
    n ← n + 1
  elseif wr
    wr ← false
  elseif n > 0 && txe && !wr
    n ← n - 1
    wr ← true
  elseif rxf && !rd && go
    rd ← true
  end
end

@wire Fifo data ← ifelse(wr, drive(got + got), release())

@testset "FT2232H: the host's side of the USB FIFO" begin
  sim = Simulation(Fifo(); clocks = (@clocks begin clk = 48MHz end))
  ft = FT2232H(sim; data = "data", rd = "rd", wr = "wr", rxf = "rxf", txe = "txe", frame = 2, timeout = 1ms)
  sim["go"] = true
  @test write(ft, [0x11, 0x22]) == 2
  @test read(ft) == [0x22, 0x44]
  put!(ft, [0x03]); @run sim advance_by(10us)
  @test take!(ft) == UInt8[] && bytesavailable(ft) == 1 && readavailable(ft) == [0x06]
  close(ft)
  @test isempty(sim.hooks)
end

# wires only: the design does nothing but give the nets a clock grid
@quartz struct Wires
  @in sclk::Bool = false
  @in mosi::Bool = false
  @in miso::Bool = false
  @in cs::Bool = false
  tick::Bool = false
end

@on Wires posedge(clk) begin
  tick ← !tick
end

@testset "SPI: a master and a slave on the same wires" begin
  for mode in 0:3
    sim = Simulation(Wires(); clocks = (@clocks begin clk = 48MHz end))
    m = SPIMaster(sim; sclk = "sclk", mosi = "mosi", miso = "miso", cs = "cs", rate = 2MHz, mode)
    sl = SPISlave(sim; sclk = "sclk", mosi = "mosi", miso = "miso", cs = "cs", mode, idle = 0xa5)
    put!(sl, [0x10, 0x20])
    @test transfer(m, [0x01, 0x02, 0x03]) == [0x10, 0x20, 0xa5]
    @test take!(sl) == [0x01, 0x02, 0x03]
    on(sl) do b; b .+ 0x40; end                    # a device answering each command byte
    @test transfer(m, [0x01, 0x02, 0x00]) == [0xa5, 0x41, 0x42]
    @test read(m, 2) == [0x40, 0x40]                 # the reply to the last byte, then to the next
    close(sl)
  end
end

@quartz struct Bus
  @io scl::Pad{1} = Pad{1}(:pullup)
  @io sda::Pad{1} = Pad{1}(:pullup)
  tick::Bool = false
end

@on Bus posedge(clk) begin
  tick ← !tick
end

# the bus as a master sees it, decoded from what the master drove
function i2cdecode(out)
  scl, sda = changes(out.scl), changes(out.sda)
  level(ch, t) = (i = searchsortedlast(first.(ch), t); i == 0 ? true : ch[i].second)
  events = String[]
  bits = Bool[]
  for (t, v) in sda[2:end]                        # the first entry is the initial level
    level(scl, t) === true || continue
    push!(events, v === true ? "P" : "S")
  end
  for (t, v) in scl[2:end]
    v === true && push!(bits, level(sda, t))
  end
  (events, bits)
end

@testset "I2C: a master's transaction on the wire, and a slave answering a master" begin
  sim = Simulation(Bus(); clocks = (@clocks begin clk = 48MHz end), watch = "*")
  m = I2CMaster(sim; scl = "scl", sda = "sda", rate = 400kHz)
  @test write(m, 0x51, [0xa5]) === false          # nobody acknowledges
  events, bits = i2cdecode(capture(sim))
  @test events == ["S", "P"]
  @test bits[1:8] == [1, 0, 1, 0, 0, 0, 1, 0] && bits[9] === true   # 0x51 << 1, not acked
  @test time(sim) < 60us
  sim2 = Simulation(Bus(); clocks = (@clocks begin clk = 48MHz end))
  sl = I2CSlave(sim2; scl = "scl", sda = "sda", address = 0x51)
  @test isempty(take!(sl))
  close(sl)
end

@testset "a wait that times out leaves the simulation usable" begin
  sim = Simulation(Bus(); clocks = (@clocks begin clk = 48MHz end))
  t0 = time(sim)
  @test_throws "timed out" @run sim advance_until(sim.scl === false; timeout = 10us)
  @test time(sim) ≈ t0 + 10e-6 atol = 1 / 48e6             # the wait ran its course
  @run sim advance_by(5us)                                 # and the run goes on from there
  @test time(sim) ≈ t0 + 15e-6 atol = 1 / 48e6
  @test isempty(sim.tasks)
end

@quartz struct Pin
  @in x::Bool = false
  tick::Bool = false
end

@on Pin posedge(clk) begin
  tick ← !tick
end

@testset "PWM: a clock, a pulse, a change of duty" begin
  sim = Simulation(Pin(); clocks = (@clocks begin clk = 48MHz end), watch = "*")
  p = PWM(sim; out = "x", rate = 1MHz, duty = 0.25)
  @run sim advance_by(3us)
  slots(ch) = [round(Int, t * 48e6) => v for (t, v) in ch]   # a drive is seen one slot on
  @test slots(changes(capture(sim).x))[2:5] == [1 => true, 13 => false, 49 => true, 61 => false]
  p.duty = 0.5
  @run sim advance_by(2us)
  @test slots(changes(capture(sim).x))[end] == (217 => false)
  close(p)
  @test !isopen(p) && sim["x"] === false
  q = PWM(sim; out = "x", rate = 1MHz, count = 1, phase = 0.5)
  @run sim advance_by(3us)
  @test length(changes(capture(sim).x)) == 11 + 2 && sim["x"] === false
end

@testset "RAM: a memory with its ports named by role" begin
  r = RAM(16, 8; read = (clock = :rdclock, addr = :rdaddress, data = :q, en = :rdclocken),
                 write = (clock = :wrclock, addr = :wraddress, data = :data, we = :we))
  r[3] = 0x5a
  @test r[3] == 0x5a && r.q == 0
  step(r, :rdclock; rdaddress = 3, rdclocken = true)
  @test r.q == 0x5a
  step(r, :wrclock; wraddress = 3, data = 0x77, we = true)
  step(r, :rdclock; rdaddress = 3, rdclocken = false)
  @test r.q == 0x5a && r[3] == 0x77
  step(r, :rdclock; rdaddress = 3, rdclocken = true)
  @test r.q == 0x77 && length(r) == 16
  fill!(r, 0)
  @test r[3] == 0
  @test_throws ErrorException r.nothere
end
