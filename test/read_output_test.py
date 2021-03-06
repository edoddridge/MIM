'''Unit tests for Aronnax'''

from contextlib import contextmanager
import os.path as p
import re

import numpy as np
from scipy.io import FortranFile

import aronnax as aro
from aronnax.utils import working_directory

import pytest
import glob

self_path = p.dirname(p.abspath(__file__))


def test_open_mfdataarray_u_location():
    '''Open a number of files and assert that the length of the iter
        dimension is the same as the number of files, and that the
        correct x and y variables have been used.'''

    xlen = 1e6
    ylen = 2e6
    nx = 10; ny = 20
    layers = 1
    grid = aro.Grid(nx, ny, layers, xlen / nx, ylen / ny)

    with working_directory(p.join(self_path, "beta_plane_gyre_red_grav")):

        output_files = glob.glob('output/snap.u*')
        ds = aro.open_mfdataarray(output_files, grid)

        assert len(output_files) == ds.iter.shape[0]
        assert nx+1 == ds.xp1.shape[0]
        assert ny == ds.y.shape[0]

def test_open_mfdataarray_v_location():
    '''Open a number of files and assert that the length of the iter
        dimension is the same as the number of files, and that the
        correct x and y variables have been used.'''

    xlen = 1e6
    ylen = 2e6
    nx = 10; ny = 20
    layers = 1
    grid = aro.Grid(nx, ny, layers, xlen / nx, ylen / ny)

    with working_directory(p.join(self_path, "beta_plane_gyre_red_grav")):

        output_files = glob.glob('output/snap.v*')
        ds = aro.open_mfdataarray(output_files, grid)

        assert len(output_files) == ds.iter.shape[0]
        assert nx == ds.x.shape[0]
        assert ny+1 == ds.yp1.shape[0]

def test_open_mfdataarray_h_location():
    '''Open a number of files and assert that the length of the iter
        dimension is the same as the number of files, and that the
        correct x and y variables have been used.'''

    xlen = 1e6
    ylen = 2e6
    nx = 10; ny = 20
    layers = 1
    grid = aro.Grid(nx, ny, layers, xlen / nx, ylen / ny)

    with working_directory(p.join(self_path, "beta_plane_gyre_red_grav")):
        output_files = glob.glob('output/snap.h*')
        ds = aro.open_mfdataarray(output_files, grid)

        assert len(output_files) == ds.iter.shape[0]
        assert nx == ds.x.shape[0]
        assert ny == ds.y.shape[0]
    

def test_open_mfdataarray_multiple_variables():
    '''This test tries to open multiple different variables in the same call,
        and should fail.'''
    
    xlen = 1e6
    ylen = 2e6
    nx = 10; ny = 20
    layers = 1
    grid = aro.Grid(nx, ny, layers, xlen / nx, ylen / ny)

    with working_directory(p.join(self_path, "beta_plane_gyre_red_grav")):
        with pytest.raises(Exception):
            output_files = glob.glob('output/snap.*')
            ds = aro.open_mfdataarray(output_files, grid)
            