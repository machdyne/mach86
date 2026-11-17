#!/usr/bin/env python3
"""Print the slowest path of one clock from a nextpnr log, briefly.

usage: critpath.py PNR_LOG [CLOCK_NAME_PART]     (default clock: 'clk')
"""
import re
import sys


def main():
    log = open(sys.argv[1]).read().split('\n')
    want = sys.argv[2] if len(sys.argv) > 2 else "$glbnet$clk'"
    starts = [i for i, l in enumerate(log)
              if 'Critical path report for clock' in l and want in l
              and 'posedge -> posedge' in l]
    if not starts:
        sys.exit('no such clock in the log')
    for l in log[starts[-1]:]:
        m = re.search(r'(clk-to-q|logic|routing|setup)\s+([\d.]+)\s+([\d.]+)\s+'
                      r'(Source|Net)\s+(\S+)', l)
        if m and m.group(1) != 'routing':
            name = m.group(5)
            name = re.sub(r'(_[A-Z0-9]+){4,}.*', '...', name)
            print('%6s ns  %-8s %s' % (m.group(3), m.group(1), name[:90]))
        if 'ns logic' in l:
            print(l.replace('Info: ', ''))
            break


if __name__ == '__main__':
    main()
