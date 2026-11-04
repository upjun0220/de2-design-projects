library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb is end tb;

architecture sim of tb is
    signal clk : std_logic := '0';
    signal KEY : std_logic_vector(3 downto 0) := "1111";
    signal SW  : std_logic_vector(17 downto 0) := (others => '0');
    signal LEDR : std_logic_vector(17 downto 0);
    signal LEDG : std_logic_vector(7 downto 0);
    signal H0, H1, H2, H3, H4, H5, H6, H7 : std_logic_vector(6 downto 0);

    function ch(s : std_logic_vector(6 downto 0)) return character is
    begin
        case s is
            when "1000000" => return '0';  when "1111001" => return '1';
            when "0100100" => return '2';  when "0110000" => return '3';
            when "0011001" => return '4';  when "0010010" => return '5';
            when "0000010" => return '6';  when "1111000" => return '7';
            when "0000000" => return '8';  when "0010000" => return '9';
            when "0001000" => return 'A';  when "0000011" => return 'b';
            when "1000110" => return 'C';  when "0100001" => return 'd';
            when "0000110" => return 'E';  when "0001110" => return 'F';
            when "0111111" => return '-';  when "0101111" => return 'r';
            when "1111111" => return ' ';
            when others => return '?';
        end case;
    end function;

    -- digit 0~15 -> character 0~F
    function hx(n : integer) return character is
    begin
        if n < 10 then return character'val(48 + n);
        elsif n = 11 then return 'b';     -- 7-segment shows B as b
        elsif n = 13 then return 'd';     -- 7-segment shows D as d
        else return character'val(55 + n);
        end if;
    end function;
begin
    clk <= not clk after 10 ns;

    dut : entity work.DE2_Project1
        port map (CLOCK_50 => clk, KEY => KEY, SW => SW, LEDR => LEDR, LEDG => LEDG,
                  HEX0 => H0, HEX1 => H1, HEX2 => H2, HEX3 => H3,
                  HEX4 => H4, HEX5 => H5, HEX6 => H6, HEX7 => H7);

    process
        variable errors, checks : integer := 0;
        variable exp : string(1 to 8);
        variable r, ar, q, rm : integer;

        impure function shown return string is
        begin
            return ch(H7) & ch(H6) & ch(H5) & ch(H4) & ch(H3) & ch(H2) & ch(H1) & ch(H0);
        end function;

        procedure compare(e : string; name : string) is
        begin
            checks := checks + 1;
            if shown /= e then
                errors := errors + 1;
                report "FAIL " & name & ": got [" & shown & "] expected [" & e & "]";
            end if;
        end procedure;

        -- counter shows v on HEX3~0, binary on LEDR, jackpot (green LEDs + 7777) at 777
        procedure cnt_is(v : integer; name : string) is
            variable pre : string(1 to 4);
        begin
            if v = 777 then pre := "7777"; else pre := "    "; end if;
            compare(pre & hx(v / 1000) & hx((v / 100) mod 10) & hx((v / 10) mod 10) & hx(v mod 10), name);
            checks := checks + 1;
            if LEDR /= std_logic_vector(to_unsigned(v, 18)) then
                errors := errors + 1;
                report "FAIL " & name & ": LEDR wrong";
            end if;
            checks := checks + 1;
            if (v = 777 and LEDG /= "11111111") or (v /= 777 and LEDG /= "00000000") then
                errors := errors + 1;
                report "FAIL " & name & ": LEDG wrong";
            end if;
        end procedure;

        procedure press(k : integer; n : integer) is
        begin
            KEY(k) <= '0';
            for i in 1 to n loop wait until rising_edge(clk); end loop;
            KEY(k) <= '1';
            for i in 1 to 6 loop wait until rising_edge(clk); end loop;
        end procedure;

        -- hexm = 0 : decimal mode (a, b must be 0~9),  hexm = 1 : hexadecimal mode
        procedure check_calc(a, b, op, hexm : integer) is
        begin
            SW <= (others => '0');
            SW(0) <= '1';
            if hexm = 1 then SW(3) <= '1'; end if;
            SW(17 downto 14) <= std_logic_vector(to_unsigned(a, 4));
            SW(13 downto 10) <= std_logic_vector(to_unsigned(b, 4));
            SW(2 downto 1)   <= std_logic_vector(to_unsigned(op, 2));
            wait for 1 ns;
            exp(1 to 4) := ' ' & hx(a) & ' ' & hx(b);
            if op = 3 and b = 0 then
                exp(5 to 8) := " Err";
            elsif op = 3 then
                q := a / b;  rm := a mod b;
                exp(5 to 8) := hx(q) & ' ' & 'r' & hx(rm);
            else
                case op is
                    when 0 => r := a + b;
                    when 1 => r := a - b;
                    when others => r := a * b;
                end case;
                if r < 0 then ar := -r; else ar := r; end if;
                if r < 0 then exp(5) := '-'; else exp(5) := ' '; end if;
                if hexm = 1 then
                    exp(6 to 8) := ' ' & hx(ar / 16) & hx(ar mod 16);
                else
                    exp(6 to 8) := hx(ar / 100) & hx((ar / 10) mod 10) & hx(ar mod 10);
                end if;
            end if;
            compare(exp, "calc a=" & integer'image(a) & " b=" & integer'image(b) &
                         " op=" & integer'image(op) & " hex=" & integer'image(hexm));
        end procedure;
    begin
        for i in 1 to 5 loop wait until rising_edge(clk); end loop;
        SW <= (others => '0');
        wait for 1 ns;
        cnt_is(0, "init");
        press(3, 2000);  cnt_is(1,  "KEY3 long press = +1 once");
        press(3, 3);     cnt_is(2,  "KEY3 short");
        press(2, 50);    cnt_is(4,  "KEY2 +2");
        press(1, 50);    cnt_is(3,  "KEY1 -1");
        press(0, 50);    cnt_is(0,  "KEY0 reset");
        press(1, 50);    cnt_is(0,  "0 - 1 stays 0");
        SW(1) <= '1';
        press(3, 50);    cnt_is(5,  "mode1 +5");
        press(2, 50);    cnt_is(15, "mode1 +10");
        press(1, 50);    cnt_is(10, "mode1 -5");
        press(2, 50);    press(2, 50);   cnt_is(30, "mode1 +10 x2");
        press(0, 50);    cnt_is(0, "reset");
        press(2, 50);    press(2, 50);   press(2, 50);   press(2, 50);   press(2, 50);   cnt_is(50, "digits 50");
        SW(1) <= '0';
        press(3, 50);    cnt_is(51, "mode0 +1");
        for i in 1 to 4 loop press(2, 50); end loop;
        cnt_is(59, "+2 x4");
        -- 1234
        SW(1) <= '1'; press(0, 50);
        for i in 1 to 123 loop press(2, 20); end loop;   -- 1230
        SW(1) <= '0';
        for i in 1 to 4 loop press(3, 20); end loop;     -- 1234
        cnt_is(1234, "1234 digits");
        -- upper limit
        SW(1) <= '1';
        for i in 1 to 876 loop press(2, 20); end loop;   -- 1234 + 8760 = 9994
        cnt_is(9994, "9994");
        press(2, 20);    cnt_is(9999, "9994 +10 -> clamp 9999");
        press(3, 20);    cnt_is(9999, "9999 +5 stays");
        SW(1) <= '0';
        press(3, 20);    cnt_is(9999, "9999 +1 stays");
        press(2, 20);    cnt_is(9999, "9999 +2 stays");
        press(1, 20);    cnt_is(9998, "9999 -1");
        press(3, 20);    cnt_is(9999, "9998 +1");
        press(2, 20);    cnt_is(9999, "9999 +2 (clamp)");
        -- lower limit
        press(0, 20);    press(3, 20);   press(3, 20);   cnt_is(2, "2");
        SW(1) <= '1';
        press(1, 20);    cnt_is(0, "2 - 5 -> 0");
        -- jackpot 777
        SW(1) <= '1';
        for i in 1 to 77 loop press(2, 20); end loop;    -- 770
        cnt_is(770, "770");
        SW(1) <= '0';
        for i in 1 to 6 loop press(3, 20); end loop;
        cnt_is(776, "776 no jackpot");
        press(3, 20);    cnt_is(777, "777 jackpot on");
        press(3, 20);    cnt_is(778, "778 jackpot off");
        press(1, 20);    cnt_is(777, "777 again jackpot on");
        SW(0) <= '1';  wait for 1 ns;
        checks := checks + 1;
        if LEDG /= "00000000" or LEDR /= "000000000000000000" then
            errors := errors + 1;
            report "FAIL LEDs must be off in calculator mode";
        end if;
        SW(0) <= '0';  wait for 1 ns;
        cnt_is(777, "back to counter mode, value kept");
        -- simultaneous press
        press(0, 20);
        KEY(3) <= '0'; KEY(2) <= '0';
        for i in 1 to 20 loop wait until rising_edge(clk); end loop;
        KEY(3) <= '1'; KEY(2) <= '1';
        for i in 1 to 6 loop wait until rising_edge(clk); end loop;
        report "simultaneous KEY3+KEY2 -> [" & shown & "]";
        -- buttons ignored in calculator mode
        press(0, 20);  press(3, 20);  press(3, 20);  press(3, 20);   -- 0 -> 3
        cnt_is(3, "before calc mode");
        SW(0) <= '1'; wait for 1 ns;
        press(3, 50); press(2, 50); press(0, 50);
        SW(0) <= '0'; wait for 1 ns;
        cnt_is(3, "buttons ignored in calc mode, value kept");
        -- calculator, decimal mode : A, B = 0~9, all four operations
        for op in 0 to 3 loop
            for a in 0 to 9 loop
                for b in 0 to 9 loop
                    check_calc(a, b, op, 0);
                end loop;
            end loop;
        end loop;
        -- calculator, hexadecimal mode : A, B = 0~F, all four operations
        for op in 0 to 3 loop
            for a in 0 to 15 loop
                for b in 0 to 15 loop
                    check_calc(a, b, op, 1);
                end loop;
            end loop;
        end loop;
        -- decimal mode, A or B is 10~15 : that input and the whole result must be blank
        for op in 0 to 3 loop
            for a in 0 to 15 loop
                for b in 0 to 15 loop
                    if a >= 10 or b >= 10 then
                        SW <= (others => '0');
                        SW(0) <= '1';
                        SW(17 downto 14) <= std_logic_vector(to_unsigned(a, 4));
                        SW(13 downto 10) <= std_logic_vector(to_unsigned(b, 4));
                        SW(2 downto 1)   <= std_logic_vector(to_unsigned(op, 2));
                        wait for 1 ns;
                        exp := "        ";
                        if a < 10 then exp(2) := hx(a); end if;
                        if b < 10 then exp(4) := hx(b); end if;
                        compare(exp, "invalid a=" & integer'image(a) & " b=" & integer'image(b) &
                                     " op=" & integer'image(op));
                    end if;
                end loop;
            end loop;
        end loop;
        -- SW3 must not matter in counter mode
        SW <= (others => '0');
        SW(3) <= '1';
        wait for 1 ns;
        cnt_is(3, "SW3 ignored in counter mode");
        report "TOTAL checks=" & integer'image(checks) & " errors=" & integer'image(errors);
        finish;
    end process;
end sim;
