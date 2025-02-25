-- Original file is copyright by Grant Searle 2014
-- Grant Searle's web site http://searle.hostei.com/grant/    
-- Grant Searle's "multicomp" page at http://searle.hostei.com/grant/Multicomp/index.html
--
-- MC6800 CPU running MIKBUG from back in the day
-- Changes to this code by Doug Gilliland 2020
-- Hardware is RETRO-EP4 Card
--		http://land-boards.com/blwiki/index.php?title=RETRO-EP4
--	48KB External RAM version
-- 32 of 8K banks from $C000-$DFFF in External SRAM
-- Bank Select register (5 bits)
-- MIKBUG ROM - 60 KB version
--		http://www.retrotechnology.com/restore/smithbug.html
-- Select Jumper (FPGA Pin 85 on P4) switches between
--		VDU (Video Display Unit) VGA + PS/2 keyboard
--		External Serial Port
--	Memory Map
--		x0000-xbfff - 48KB SRAM
--		xc000-xdfff - 8Kb SRAM banks (32 banks)
--		xe000-xefff - 4KB SRAM
--		xf000-xffff - 4 KB ROM
--		xfc00-xfcff - I/O space
--			xfc18-xfc19 - VDU/UART (6850 Interface)
--			xfc28-xfc29 - UART.VDU (6850 Interface)
--			xfc30 - Bank Select register (r/w)
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use  IEEE.STD_LOGIC_ARITH.all;
use  IEEE.STD_LOGIC_UNSIGNED.all;

entity M6800_MIKBUG is
	port(
		i_n_reset			: in std_logic := '1';
		i_CLOCK_50			: in std_logic;

		-- VGA
		o_videoR0			: out std_logic := '1';
		o_videoR1			: out std_logic := '1';
		o_videoG0			: out std_logic := '1';
		o_videoG1			: out std_logic := '1';
		o_videoB0			: out std_logic := '1';
		o_videoB1			: out std_logic := '1';
		o_hSync				: out std_logic := '1';
		o_vSync				: out std_logic := '1';

		-- PS/2
		io_ps2Clk			: inout std_logic := '1';
		io_ps2Data			: inout std_logic := '1';
		
		-- Serial
		rxd1					: in std_logic := '1';
		txd1					: out std_logic;
		i_n_cts1				: in std_logic := '1';
		o_n_rts1				: out std_logic;
		serSelect			: in std_logic := '1';
		
		o_ledOut				: out std_logic_vector(3 downto 0) := "1111";
		
		-- External SRAM
		io_extSRamData		: inout std_logic_vector(7 downto 0) := "ZZZZZZZZ";
		o_extSRamAddress	: out std_logic_vector(18 downto 0) := "000"&x"0000";
		o_n_extSRamWE		: out std_logic := '1';
		o_n_extSRamCS		: out std_logic := '1';
		o_n_extSRamOE		: out std_logic := '1'
	);
end M6800_MIKBUG;

architecture struct of M6800_MIKBUG is

	signal w_resetLow		: std_logic := '1';

	-- CPU Signals
	signal w_cpuAddress	: std_logic_vector(15 downto 0);
	signal w_cpuDataOut	: std_logic_vector(7 downto 0);
	signal w_cpuDataIn	: std_logic_vector(7 downto 0);
	signal w_R1W0			: std_logic;
	signal w_vma			: std_logic;

	-- Memory and Peripheral Data
	signal w_romData		: std_logic_vector(7 downto 0);
	signal w_sramData		: std_logic_vector(7 downto 0);
	signal w_if1DataOut	: std_logic_vector(7 downto 0);
	signal w_if2DataOut	: std_logic_vector(7 downto 0);
	
	-- Memory controls
	signal w_n_SRAMCE		: std_logic;
	signal w_bankAdr		: std_logic;
	signal w_ldAdrVal		: std_logic;
	signal adrLatVal		: std_logic_vector(7 downto 0);

	-- Interface control lines
	signal n_int1			: std_logic :='1';	
	signal n_if1CS			: std_logic :='1';
	signal n_int2			: std_logic :='1';	
	signal n_if2CS			: std_logic :='1';

	-- CPU Clock
	signal q_cpuClkCount	: std_logic_vector(5 downto 0); 
	signal w_cpuClock		: std_logic;

   -- External Serial Port Cloc
	signal serialCount         	: std_logic_vector(15 downto 0) := x"0000";
   signal serialCount_d       	: std_logic_vector(15 downto 0);
   signal serialEn            	: std_logic;
	
begin
	
	o_ledOut(3) <= w_n_SRAMCE;
	o_ledOut(2) <= n_if1CS;
	o_ledOut(1) <= '0' when ((w_cpuAddress(15 downto 12) = "1111") and (w_vma = '1'))	else '1';
	o_ledOut(0) <= not adrLatVal(7);

	-- Debounce the reset line
	DebounceResetSwitch	: entity work.Debouncer
	port map (
		i_clk		=> w_cpuClock,
		i_PinIn	=> i_n_reset,
		o_PinOut	=> w_resetLow
	);
	
	-- External SRAM
	w_n_SRAMCE	<= '0'   when w_cpuAddress(15) 			  = '0' else		-- 32KB SRAM $0000-$7FFF
						'0'   when w_cpuAddress(15 downto 14) = "10" else		-- 16KB SRAM $8000-$BFFF
						'0'   when w_cpuAddress(15 downto 13) = "110" else		-- 8KB SRAM  $C000-$DFFF
						'0'   when w_cpuAddress(15 downto 12) = "1110" else	-- 4KB SRAM  $E000-$EFFF
						'1';
	w_bankAdr	<= '1' when w_cpuAddress(15 downto 13) = "110" else '0';
	o_n_extSRamCS <= w_n_SRAMCE                 or (not w_vma);
	o_n_extSRamWE <= w_n_SRAMCE or      w_R1W0  or (not w_vma)  or (not w_cpuClock);
	o_n_extSRamOE <= w_n_SRAMCE or (not w_R1W0) or (not w_vma);
	o_extSRamAddress(18)					<= '1' when w_cpuAddress(15 downto 13) = "110" else '0';
	o_extSRamAddress(17 downto 16) 	<= "00" when w_cpuAddress(15 downto 13) = "110"  else adrLatVal(4 downto 3);
	o_extSRamAddress(15 downto 13) 	<= w_cpuAddress(15 downto 13) when w_bankAdr = '0' else adrLatVal(2 downto 0);
	o_extSRamAddress(12 downto 0) 	<= w_cpuAddress(12 downto 0);
	io_extSRamData <= w_cpuDataOut when ((w_n_SRAMCE = '0') and (w_R1W0 = '0')) else (others => 'Z');

	addrLatch : entity work.OutLatch
		port map (	
			dataIn	=> w_cpuDataOut,
			clock		=> i_CLOCK_50,
			load		=> w_ldAdrVal or w_R1W0 or (not w_vma) or (not w_cpuClock),
			clear		=> w_resetLow,
			latchOut	=> adrLatVal
		);
		
	-- ____________________________________________________________________________________
	-- 6800 CPU
	cpu1 : entity work.cpu68
		port map(
			clk		=> w_cpuClock,
			rst		=> not w_resetLow,
			rw			=> w_R1W0,
			vma		=> w_vma,
			address	=> w_cpuAddress,
			data_in	=> w_cpuDataIn,
			data_out	=> w_cpuDataOut,
			hold		=> '0',
			halt		=> '0',
			irq		=> '0',
			nmi		=> '0' 
		); 
	
	-- ____________________________________________________________________________________
	-- MIKBUG ROM
	-- 4KB MIKBUG ROM - repeats in memory 4 times
	rom1 : entity work.MIKBUG 		
		port map(
			address	=> w_cpuAddress(11 downto 0),
			clock 	=> i_CLOCK_50,
			q			=> w_romData
		);
		
	-- ____________________________________________________________________________________
	-- I/O CHIP SELECTS
	n_if1CS	<= '0' 	when (serSelect = '1' and (w_cpuAddress(15 downto 1) = x"FC1"&"100")) else	-- VDU $FC18-$FC19
					'0'	when (serSelect = '0' and (w_cpuAddress(15 downto 1) = x"FC2"&"100")) else
					'1';
	n_if2CS	<= '0' 	when (serSelect = '1' and (w_cpuAddress(15 downto 1) = x"FC2"&"100")) else	-- ACIA $FC28-$FC29
					'0'	when (serSelect = '0' and (w_cpuAddress(15 downto 1) = x"FC1"&"100")) else
					'1';
	w_ldAdrVal <= '0' when (w_cpuAddress = x"FC30") else '1';
	
	-- ____________________________________________________________________________________
	-- INPUT/OUTPUT DEVICES
	-- Grant's VGA driver
	vdu : entity work.SBCTextDisplayRGB
	generic map ( 
		EXTENDED_CHARSET		=> 1,
		COLOUR_ATTS_ENABLED	=>	1
	)
		port map (
			n_reset	=> w_resetLow,
			clk		=> i_CLOCK_50,
			
			-- RGB Compo_video signals
			hSync		=> o_hSync,
			vSync		=> o_vSync,
			videoR0	=> o_videoR0,
			videoR1	=> o_videoR1,
			videoG0	=> o_videoG0,
			videoG1	=> o_videoG1,
			videoB0	=> o_videoB0,
			videoB1	=> o_videoB1,
			n_WR		=> n_if1CS or      w_R1W0  or (not w_vma) or (not w_cpuClock),
			n_rd		=> n_if1CS or (not w_R1W0) or (not w_vma),
			n_int		=> n_int1,
			regSel	=> w_cpuAddress(0),
			dataIn	=> w_cpuDataOut,
			dataOut	=> w_if1DataOut,
			ps2Clk	=> io_ps2Clk,
			ps2Data	=> io_ps2Data
		);
	
	acia: entity work.bufferedUART
		port map (
			clk		=> i_CLOCK_50,     
			n_WR		=> n_if2CS or      w_R1W0  or (not w_vma) or (not w_cpuClock),
			n_rd		=> n_if2CS or (not w_R1W0) or (not w_vma),
			regSel	=> w_cpuAddress(0),
			dataIn	=> w_cpuDataOut,
			dataOut	=> w_if2DataOut,
			n_int		=> n_int2,
						 -- these clock enables are asserted for one period of input clk,
						 -- at 16x the baud rate.
			rxClkEn	=> serialEn,
			txClkEn	=> serialEn,
			rxd		=> rxd1,
			txd		=> txd1
		);
	
	-- ____________________________________________________________________________________
	-- CPU Read Data multiplexer
	w_cpuDataIn <=
		io_extSRamData	when (w_n_SRAMCE = '0')	else
		w_if1DataOut	when (n_if1CS = '0')	else
		w_if2DataOut	when (n_if2CS = '0')	else
		adrLatVal		when (w_ldAdrVal = '0') else
		w_romData		when w_cpuAddress(15 downto 12) = "1111"	else
		x"FF";
	
	-- ____________________________________________________________________________________
	-- CPU Clock
process (i_CLOCK_50)
	begin
		if rising_edge(i_CLOCK_50) then
			if q_cpuClkCount < 4 then
				q_cpuClkCount <= q_cpuClkCount + 1;
			else
				q_cpuClkCount <= (others=>'0');
			end if;
			if q_cpuClkCount < 2 then
				w_cpuClock <= '0';
			else
				w_cpuClock <= '1';
			end if;
		end if;
	end process;
	
	-- Baud Rate CLOCK SIGNALS
    -- Serial clock DDS. With 50MHz master input clock:
    -- Baud   Increment
    -- 115200 2416
    -- 38400  805
    -- 19200  403
    -- 9600   201
    -- 4800   101
    -- 2400   50
	
baud_div: process (serialCount_d, serialCount)
    begin
        serialCount_d <= serialCount + 2416;
    end process;

process (i_CLOCK_50)
	begin
		if rising_edge(i_CLOCK_50) then
        -- Enable for baud rate generator
        serialCount <= serialCount_d;
        if serialCount(15) = '0' and serialCount_d(15) = '1' then
            serialEn <= '1';
        else
            serialEn <= '0';
        end if;
		end if;
	end process;

end;