# -*- coding: utf-8 -*-
import os
import sys
import argparse
import numpy as np
import h5py
import itertools
from collections import defaultdict

def main(arguments):
	parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
	parser.add_argument('--srcfile', help="Path to source training data, ", required=True)
	parser.add_argument('--targetfile', help="Path to target training data, ", required=True)
	parser.add_argument('--srcoutputfile', help="Prefix of the output file names. ", type=str, required=True)
	parser.add_argument('--targoutputfile', help="Prefix of the output file names. ", type=str, required=True)
	parser.add_argument('--saveevery',help="save every #sentence",type = int,default=2)
	args = parser.parse_args(arguments)
	filesrc = open(args.srcoutputfile,"a")
	filetarg = open(args.targoutputfile,"a")
	for n, (src_orig, targ_orig) in enumerate(itertools.izip(open(args.srcfile,'r'), open(args.targetfile,'r'))):
		if (int(n)%args.saveevery) == 0:
			filesrc.write(src_orig)
			filetarg.write(targ_orig)
	print("process finished")


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
