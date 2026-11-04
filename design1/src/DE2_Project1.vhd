-- DE2 Design Project #1 : Counter + One Digit Calculator (with bonus)
-- SW0 : 0 = counter, 1 = calculator
-- Counter    : SW1 = mode, KEY3/KEY2/KEY1 = change value, KEY0 = reset
--              HEX3~0 = value, LEDR = value in binary
--              jackpot at 777 : green LEDs on and HEX7~4 show 7777
-- Calculator : SW17~14 = A, SW13~10 = B, SW2~1 = operation (00 +, 01 -, 10 *, 11 /)
--              SW3 = 0 : decimal (0~9),  SW3 = 1 : hexadecimal (0~F)
--              A on HEX6, B on HEX4, result on HEX3~0
--              division shows "quotient r remainder", for example 7 / 3 -> "2 r1"
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
        HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7 : out std_logic_vector(6 downto 0)
    );
end DE2_Project1;

architecture behavior of DE2_Project1 is
    -- character codes : 0~15 = hex digit 0~F, 16 = blank, 17 = '-', 18 = 'r'
    constant BLANK : integer := 16;
    constant MINUS : integer := 17;
    constant CH_R  : integer := 18;
    constant CH_E  : integer := 14;   -- same shape as hex E

    signal k1, k2 : std_logic_vector(3 downto 0) := "1111";  -- buttons now / one clock ago
    signal cnt    : integer range 0 to 9999 := 0;            -- counter value
    signal s1, s2 : integer range 0 to 10;                   -- step size
    signal a, b   : integer range 0 to 15;                   -- calculator inputs
    signal result : integer range 0 to 255;                  -- result of + - * (absolute value)
    signal quot   : integer range 0 to 15;                   -- quotient
    signal remain : integer range 0 to 15;                   -- remainder
    signal neg    : std_logic;                               -- 1 = negative result
    signal err    : std_logic;                               -- 1 = divide by zero
    signal valid  : std_logic;                               -- 0 = decimal mode and A or B is 10 or more
    signal d0, d1, d2, d3, d4, d5, d6, d7 : integer range 0 to 18;  -- what each HEX shows

    -- 7-segment pattern of each character code (a segment lights up when 0)
    type seg_table is array (0 to 18) of std_logic_vector(6 downto 0);
    constant SEG7 : seg_table := (
        "1000000", "1111001", "0100100", "0110000", "0011001",   -- 0 1 2 3 4
        "0010010", "0000010", "1111000", "0000000", "0010000",   -- 5 6 7 8 9
        "0001000", "0000011", "1000110", "0100001", "0000110", "0001110",   -- A b C d E F
        "1111111", "0111111", "0101111");                        -- blank - r
begin
    -- counter : change the value only at the moment a button is pressed (1 -> 0)
    s1 <= 1 when SW(1) = '0' else 5;     -- step of button1 (+) and button3 (-)
    s2 <= 2 when SW(1) = '0' else 10;    -- step of button2 (+)

    process (CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            k1 <= KEY;
            k2 <= k1;
            if SW(0) = '0' then          -- counter mode only
                if k2(0) = '1' and k1(0) = '0' then          -- KEY0 : reset
                    cnt <= 0;
                elsif k2(3) = '1' and k1(3) = '0' then       -- KEY3 : up by s1
                    if cnt + s1 > 9999 then cnt <= 9999; else cnt <= cnt + s1; end if;
                elsif k2(2) = '1' and k1(2) = '0' then       -- KEY2 : up by s2
                    if cnt + s2 > 9999 then cnt <= 9999; else cnt <= cnt + s2; end if;
                elsif k2(1) = '1' and k1(1) = '0' then       -- KEY1 : down by s1
                    if cnt < s1 then cnt <= 0; else cnt <= cnt - s1; end if;
                end if;
            end if;
        end if;
    end process;

    -- LEDs (counter mode only) : red = value in binary, green = jackpot at 777
    LEDR <= std_logic_vector(to_unsigned(cnt, 18)) when SW(0) = '0' else (others => '0');
    LEDG <= (others => '1') when SW(0) = '0' and cnt = 777 else (others => '0');

    -- calculator : 00 add, 01 subtract, 10 multiply, 11 divide
    a <= to_integer(unsigned(SW(17 downto 14)));
    b <= to_integer(unsigned(SW(13 downto 10)));
    err <= '1' when SW(2 downto 1) = "11" and b = 0 else '0';
    valid <= '1' when SW(3) = '1' or (a < 10 and b < 10) else '0';

    process (SW, a, b)
        variable q : integer range 0 to 15;
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
                    result <= b - a;     -- a is smaller : calculate b - a and mark negative
                    neg <= '1';
                end if;
            when "10" => result <= a * b;
            when others =>
                if b /= 0 then
                    q := to_integer(to_unsigned(a, 4) / to_unsigned(b, 4));
                    quot <= q;
                    remain <= a - q * b;     -- remainder = a - quotient * b
                end if;
        end case;
    end process;

    -- decide what each 7-segment shows
    process (SW, cnt, a, b, result, quot, remain, neg, err, valid)
    begin
        d7 <= BLANK; d6 <= BLANK; d5 <= BLANK; d4 <= BLANK;     -- everything off first
        d3 <= BLANK; d2 <= BLANK; d1 <= BLANK; d0 <= BLANK;

        if SW(0) = '0' then              -- counter : thousands, hundreds, tens, ones
            d3 <= cnt / 1000;
            d2 <= (cnt / 100) mod 10;
            d1 <= (cnt / 10) mod 10;
            d0 <= cnt mod 10;
            if cnt = 777 then            -- jackpot : show 7777
                d7 <= 7; d6 <= 7; d5 <= 7; d4 <= 7;
            end if;
        else                             -- calculator
            if SW(3) = '1' or a < 10 then d6 <= a; end if;   -- decimal mode shows 0~9 only
            if SW(3) = '1' or b < 10 then d4 <= b; end if;
            if valid = '1' then
                if err = '1' then                            -- divide by zero : " Err"
                    d2 <= CH_E;  d1 <= CH_R;  d0 <= CH_R;
                elsif SW(2 downto 1) = "11" then             -- division : "quotient r remainder"
                    d3 <= quot;  d1 <= CH_R;  d0 <= remain;
                else
                    if neg = '1' then d3 <= MINUS; end if;
                    if SW(3) = '1' then                      -- hexadecimal result : 2 digits
                        d1 <= result / 16;
                        d0 <= result mod 16;
                    else                                     -- decimal result : 3 digits
                        d2 <= result / 100;
                        d1 <= (result / 10) mod 10;
                        d0 <= result mod 10;
                    end if;
                end if;
            end if;
        end if;
    end process;

    HEX0 <= SEG7(d0);  HEX1 <= SEG7(d1);  HEX2 <= SEG7(d2);  HEX3 <= SEG7(d3);
    HEX4 <= SEG7(d4);  HEX5 <= SEG7(d5);  HEX6 <= SEG7(d6);  HEX7 <= SEG7(d7);
end behavior;
