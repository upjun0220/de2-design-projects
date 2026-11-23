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
    constant BLANK : integer := 16;
    constant MINUS : integer := 17;
    constant CH_R  : integer := 18;
    constant CH_E  : integer := 14;

    signal k1, k2 : std_logic_vector(3 downto 0) := "1111";
    signal cnt    : integer range 0 to 9999 := 0;
    signal s1, s2 : integer range 0 to 10;
    signal a, b   : integer range 0 to 15;
    signal base   : integer range 10 to 16;
    signal result : integer range 0 to 255;
    signal valid  : std_logic;

    type digit_array is array (7 downto 0) of integer range 0 to 18;
    signal d : digit_array;

    type seg_table is array (0 to 18) of std_logic_vector(6 downto 0);
    constant SEG7 : seg_table := (
        "1000000", "1111001", "0100100", "0110000", "0011001",
        "0010010", "0000010", "1111000", "0000000", "0010000",
        "0001000", "0000011", "1000110", "0100001", "0000110", "0001110",
        "1111111", "0111111", "0101111");

    signal jp   : std_logic;
begin
    s1 <= 1 when SW(1) = '0' else 5;
    s2 <= 2 when SW(1) = '0' else 10;

    process (CLOCK_50)
    begin
        if rising_edge(CLOCK_50) then
            k1 <= KEY;
            k2 <= k1;
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
    LEDG <= (others => jp);

    a      <= to_integer(unsigned(SW(17 downto 14)));
    b      <= to_integer(unsigned(SW(13 downto 10)));
    base   <= 16 when SW(3) = '1' else 10;
    valid  <= '1' when SW(3) = '1' or (a < 10 and b < 10) else '0';
    result <= a + b      when SW(2 downto 1) = "00" else
              abs(a - b) when SW(2 downto 1) = "01" else
              a * b;

    process (SW, cnt, a, b, base, result, valid)
    begin
        d <= (others => BLANK);

        if SW(0) = '0' then
            d(3) <= cnt / 1000;
            d(2) <= (cnt / 100) mod 10;
            d(1) <= (cnt / 10) mod 10;
            d(0) <= cnt mod 10;
            if cnt = 777 then d(7 downto 4) <= (others => 7); end if;
        else
            if SW(3) = '1' or a < 10 then d(6) <= a; end if;
            if SW(3) = '1' or b < 10 then d(4) <= b; end if;
            if valid = '1' then
                if SW(2 downto 1) /= "11" then
                    if SW(2 downto 1) = "01" and a < b then d(3) <= MINUS; end if;
                    d(1) <= result / base;
                    d(0) <= result mod base;
                elsif b = 0 then
                    d(2) <= CH_E;  d(1) <= CH_R;  d(0) <= CH_R;
                else
                    d(3) <= a / b;  d(1) <= CH_R;  d(0) <= a mod b;
                end if;
            end if;
        end if;
    end process;

    HEX0 <= SEG7(d(0));  HEX1 <= SEG7(d(1));  HEX2 <= SEG7(d(2));  HEX3 <= SEG7(d(3));
    HEX4 <= SEG7(d(4));  HEX5 <= SEG7(d(5));  HEX6 <= SEG7(d(6));  HEX7 <= SEG7(d(7));
end behavior;
