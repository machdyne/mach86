#!/usr/bin/env python3
"""Write a simulation model of the ECP5 MULT18X18D for gate-level runs.

usage: ecp5_mult_sim.py CELLS_BB_V OUT_V

Yosys ships the multiplier block as a black box only. This takes its
port list from Yosys's cells_bb.v and adds the one behaviour our
netlists use: an unregistered 18 x 18 multiply, each operand signed or
not as its SIGNED input says.
"""
import re
import sys


def main():
    text = open(sys.argv[1]).read()
    m = re.search(r'module MULT18X18D\(.*?endmodule', text, re.S)
    body = m.group(0)[:-len('endmodule')]
    a = ', '.join('A%d' % i for i in range(17, -1, -1))
    b = ', '.join('B%d' % i for i in range(17, -1, -1))
    p = ', '.join('P%d' % i for i in range(35, -1, -1))
    body += '''
\t// Simulation model: combinational, as the netlist uses it.
\twire [17:0] a_in = {%s};
\twire [17:0] b_in = {%s};
\twire signed [18:0] a_x = {SIGNEDA & a_in[17], a_in};
\twire signed [18:0] b_x = {SIGNEDB & b_in[17], b_in};
\twire signed [37:0] p_x = a_x * b_x;
\tassign {%s} = p_x[35:0];
endmodule
''' % (a, b, p)
    open(sys.argv[2], 'w').write(body)


if __name__ == '__main__':
    main()
