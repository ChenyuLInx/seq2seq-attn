# -*- coding: utf-8 -*-
import os
import sys
import argparse
import numpy as np
import itertools
from collections import defaultdict
import matplotlib.pyplot as plt
import time
def main(arguments):
	parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
	parser.add_argument('--srcfile', help="path to log of training, ", required=True)
	args = parser.parse_args(arguments)
	start = 0
	rep = 0
	model_ppl = []
	Joint_model_ppl = []
	model_ppl_en_en = []
	Joint_model_ppl_de_de = []
	x = []
	with open(args.srcfile) as f:
		content = f.readlines()
	for i, sent in enumerate(content):
		if (start == 0 and sent == 'Normal flow result:\t\n'):
			start = i
			rep += 1
			continue
		if sent.split()[0] == 'Train':
				break
		if start != 0:
			if rep == 1:
				model_ppl.append(float(sent.split()[10][:-1]))
			elif rep == 2:
				Joint_model_ppl.append(float(sent.split()[13][:-1]))
			elif rep == 4:
				model_ppl_en_en.append(float(sent.split()[10][:-1]))
			elif rep == 5:
				Joint_model_ppl_de_de.append(float(sent.split()[13][:-1]))
			rep += 1
			if rep == 6:
				rep = 0
				x.append(float(sent.split()[4][:-7]))
	plt.subplots_adjust(hspace=0.4)
	plt.subplot(221)
	plt.plot(x,model_ppl)
	plt.ylabel('ppl')
	plt.yscale('log')
	plt.subplot(222)
	plt.plot(x,Joint_model_ppl)
	plt.ylabel('ppl')
	plt.yscale('log')
	plt.subplot(223)
	plt.plot(x,model_ppl_en_en)
	plt.ylabel('ppl')
	plt.yscale('log')
	plt.subplot(224)
	plt.plot(x,Joint_model_ppl_de_de)
	plt.ylabel('ppl')
	plt.yscale('log')
	plt.show()
	# plt
	# np.savez(args.savefile, model_ppl, Joint_model_ppl, model_ppl_en_en, Joint_model_ppl_de_de)




if __name__ == '__main__':
    main(sys.argv[1:])