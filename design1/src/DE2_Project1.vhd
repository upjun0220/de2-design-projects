library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity DE2_Project1 is
    port (
        CLOCK_50 : in  std_logic;
        KEY      : in  std_logic_vector(3 downto 0);
        SW       : in  std_logic_vector(17 downto 0);
        LEDR     : out std_logic_vector(17 downto 0);
        LEDG     : out std_logic_vector(7 downto 0);
        LCD_DATA : out std_logic_vector(7 downto 0);
        LCD_RS, LCD_RW, LCD_EN, LCD_ON, LCD_BLON : out std_logic;
        HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : out std_logic_vector(6 downto 0)
    );
end DE2_Project1;

architecture behavior of DE2_Project1 is
    constant BLANK : integer := 16;
    constant MINUS : integer := 17;
    constant CH_R  : integer := 18;
    constant CH_E  : integer := 14;

    signal k1, k2 : std_logic_vector(3 downto 0) := "1111";
    signal cnt    : integer range 0 to 9999 := 0;
    signal s1, s2 : integer range 0 to 10;
    signal a, b   : integer range 0 to 15;
    signal result : integer range 0 to 255;
    signal quot   : integer range 0 to 15;
    signal remain : integer range 0 to 15;
    signal neg    : std_logic;
    signal err    : std_logic;
    signal valid  : std_logic;
    signal d0, d1, d2, d3, d4, d5, d6, d7 : integer range 0 to 18;

    type seg_table is array (0 to 18) of std_logic_vector(6 downto 0);
    constant SEG7 : seg_table := (
        "1000000", "1111001", "0100100", "0110000", "0011001",
        "0010010", "0000010", "1111000", "0000000", "0010000",
        "0001000", "0000011", "1000110", "0100001", "0000110", "0001110",
        "1111111", "0111111", "0101111");

    constant JACKPOT_TXT : string(1 to 32) := "* JACKPOT  777 *" & "CONGRATULATIONS!";
    signal tick : unsigned(23 downto 0) := (others => '0');
    signal step : integer range 0 to 41 := 0;
    signal jp   : std_logic;
begin
    s1 <= 1 when SW(1) = '0' else 5;
    s2 <= 2 when SW(1) = '0' else 10;

    process (CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            k1 <= KEY;
            k2 <= k1;
            tick <= tick + 1;
            if tick(16 downto 0) = 0 then
                if step = 41 then step <= 8; else step <= step + 1; end if;
            end if;
            if SW(0) = '0' then
                if k2(0) = '1' and k1(0) = '0' then
                    cnt <= 0;
                elsif k2(3) = '1' and k1(3) = '0' then
                    if cnt + s1 > 9999 then cnt <= 9999; else cnt <= cnt + s1; end if;
                elsif k2(2) = '1' and k1(2) = '0' then
                    if cnt + s2 > 9999 then cnt <= 9999; else cnt <= cnt + s2; end if;
                elsif k2(1) = '1' and k1(1) = '0' then
                    if cnt < s1 then cnt <= 0; else cnt <= cnt - s1; end if;
                end if;
            end if;
        end if;
    end process;

    jp   <= '1' when SW(0) = '0' and cnt = 777 else '0';
    LEDR <= std_logic_vector(to_unsigned(cnt, 18)) when SW(0) = '0' else (others => '0');
    LEDG <= (others => tick(23)) when jp = '1' else (others => '0');

    a <= to_integer(unsigned(SW(17 downto 14)));
    b <= to_integer(unsigned(SW(13 downto 10)));
    err <= '1' when SW(2 downto 1) = "11" and b = 0 else '0';
    valid <= '1' when SW(3) = '1' or (a < 10 and b < 10) else '0';

    process (SW, a, b)
    begin
        result <= 0;
        quot <= 0;
        remain <= 0;
        neg <= '0';
        case SW(2 downto 1) is
            when "00" => result <= a + b;
            when "01" =>
                if a >= b then
                    result <= a - b;
                else
                    result <= b - a;
                    neg <= '1';
                end if;
            when "10" => result <= a * b;
            when others =>
                if b /= 0 then
                    quot <= a / b;
                    remain <= a mod b;
                end if;
        end case;
    end process;

    process (SW, cnt, a, b, result, quot, remain, neg, err, valid)
    begin
        d7 <= BLANK; d6 <= BLANK; d5 <= BLANK; d4 <= BLANK;
        d3 <= BLANK; d2 <= BLANK; d1 <= BLANK; d0 <= BLANK;

        if SW(0) = '0' then
            d3 <= cnt / 1000;
            d2 <= (cnt / 100) mod 10;
            d1 <= (cnt / 10) mod 10;
            d0 <= cnt mod 10;
            if cnt = 777 then
                d7 <= 7; d6 <= 7; d5 <= 7; d4 <= 7;
            end if;
        else
            if SW(3) = '1' or a < 10 then d6 <= a; end if;
            if SW(3) = '1' or b < 10 then d4 <= b; end if;
            if valid = '1' then
                if err = '1' then
                    d2 <= CH_E;  d1 <= CH_R;  d0 <= CH_R;
                elsif SW(2 downto 1) = "11" then
                    d3 <= quot;  d1 <= CH_R;  d0 <= remain;
                else
                    if neg = '1' then d3 <= MINUS; end if;
                    if SW(3) = '1' then
                        d1 <= result / 16;
                        d0 <= result mod 16;
                    else
                        d2 <= result / 100;
                        d1 <= (result / 10) mod 10;
                        d0 <= result mod 10;
                    end if;
                end if;
            end if;
        end if;
    end process;

    LCD_RW  <= '0';  LCD_ON <= '1';  LCD_BLON <= '1';
    LCD_EN  <= '1' when tick(16 downto 15) = "10" else '0';
    LCD_RS  <= '1' when step > 8 and step /= 25 else '0';

    process (step, jp)
        variable i : integer range 1 to 32;
    begin
        i := 1;
        if step > 25 then i := step - 9; elsif step > 8 then i := step - 8; end if;
        if    step < 6  then LCD_DATA <= x"38";
        elsif step = 6  then LCD_DATA <= x"0C";
        elsif step = 7  then LCD_DATA <= x"06";
        elsif step = 8  then LCD_DATA <= x"80";
        elsif step = 25 then LCD_DATA <= x"C0";
        elsif jp = '1'  then LCD_DATA <= std_logic_vector(to_unsigned(character'pos(JACKPOT_TXT(i)), 8));
        else                 LCD_DATA <= x"20";
        end if;
    end process;

    HEX0 <= SEG7(d0);  HEX1 <= SEG7(d1);  HEX2 <= SEG7(d2);  HEX3 <= SEG7(d3);
    HEX4 <= SEG7(d4);  HEX5 <= SEG7(d5);  HEX6 <= SEG7(d6);  HEX7 <= SEG7(d7);
end behavior;
