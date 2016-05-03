import numpy as np
cimport numpy as np
from numpy.linalg import inv

from neldermead cimport NelderMeadMinimizer
from water cimport WaterModel


# TODO: deal with selection of bands in the inversion
# TODO: formalize the expression of atmospheric component
# as a sum of N arbitrary terms

cdef class F(NelderMeadMinimizer):
    '''
    Defines the cost function minimized by Polymer
    Inherits from NelderMeadMinimizer which provides method minimize
    '''

    cdef float[:] Rprime
    cdef float [:] Tmol,
    cdef float[:] wav
    cdef WaterModel w

    # [Ratm] = [A] . [C]
    # where A is the matrix of the polynomial exponents for each wavelength (nlam x ncoef)
    # [C] = [pA] . [Ratm]    where [pA] is the pseudoinverse of matrix [A]  (ncoef x nlam)
    cdef float [:,:] A
    cdef float [:,:] pA
    cdef int Ncoef

    cdef float [:] C  # ci coefficients (ncoef)

    def __init__(self, Ncoef, watermodel, *args, **kwargs):

        super(self.__class__, self).__init__(*args, **kwargs)

        self.w = watermodel
        self.C = np.zeros(Ncoef, dtype='float32')
        self.Ncoef = Ncoef

    cdef init(self, float[:] Rprime, float [:,:] A, float [:,:] pA,
            float [:] Tmol,
            float[:] wav, float sza, float vza, float raa):
        '''
        set the input parameters for the current pixel
        '''
        self.Rprime = Rprime
        self.wav = wav
        self.pA = pA
        self.A = A
        self.Tmol = Tmol

        self.w.init(wav, sza, vza, raa)


    cdef float eval(self, float[:] x) except? -999:
        '''
        Evaluate cost function for vector parameters x
        '''
        cdef float[:] Rw
        cdef float C
        cdef float sumsq, dR

        #
        # calculate the. water reflectance for the current parameters
        #
        Rw = self.w.calc_rho(x)

        #
        # atmospheric fit
        #
        for ic in range(self.Ncoef):
            C = 0.
            for il in range(len(Rw)):
                # TODO: transmission
                C += self.pA[ic,il] * (self.Rprime[il] - Rw[il])
            self.C[ic] = C

        #
        # calculate the residual
        #
        sumsq = 0.
        for il in range(len(Rw)):

            dR = self.Rprime[il]

            # subtract atmospheric signal
            for ic in range(self.Ncoef):
                dR -= self.C[ic] * self.A[il,ic]

            # TODO: divide by transmission

            dR -= Rw[il]

            # TODO:
            # Add residual to sumsq
            sumsq += dR*dR

        return sumsq

def atm_func(block, params):
    '''
    Returns the matrix of atmospheric components
    A [im0, im1, nlam, ncoef]

    Note: pseudo inverse de A
    A* = ((A'.A)^(-1)).A'     où B' est la transposée et B^-1 est l'inverse de B

    Ratm = A.C
    Ratm: (shp0, shp1, nlam)
    A   : (shp0, shp1, nlam, ncoef)
    C   : (shp0, shp1, ncoef)

    B = (A'.A) = tensordot(A, A, axes=[[0], [0]])
        (shp0, shp1, ncoef, ncoef)

    '''
    # bands for atmospheric fit
    Nlam = len(params.bands_corr)
    shp = block.size

    # correction bands wavelengths
    i_corr = np.searchsorted(params.bands_read(), params.bands_corr)
    # transpose: move the wavelength dimension to the end
    lam = np.transpose(block.wavelen[i_corr,:,:], axes=[1, 2, 0])

    # initialize the matrix for inversion
    Ncoef = 3   # number of polynomial coefficients
    A = np.zeros((shp[0], shp[1], Nlam, Ncoef), dtype='float32')

    A[:,:,:,0] = (lam/1000.)**0   # FIXME
    A[:,:,:,1] = (lam/1000.)**-1
    A[:,:,:,2] = (lam/1000.)**-4

    return A

def pseudoinverse(A):
    '''
    Calculate the pseudoinverse of array A over the last 2 axes
    (broadcasting the first axes)
    A* = ((A'.A)^(-1)).A'
    where X' is the transpose of X and X^-1 is the inverse of X
    '''

    # A'.A (with broadcasting)
    B = np.einsum('...ji,...jk->...ik', A, A)

    # check
    if B.ndim == 4:
        assert np.allclose(B[0,0,:,:], A[0,0,:,:].transpose().dot(A[0,0,:,:]))

    # (A^-1).A' (with broadcasting)
    pA = np.einsum('...ij,...kj->...ik', inv(B), A)

    # check
    if B.ndim == 4:
        assert np.allclose(pA[0,0], inv(B[0,0,:,:]).dot(A[0,0,:,:].transpose()))

    return pA


cdef class PolymerMinimizer:

    cdef F f
    cdef int Nparams

    def __init__(self, watermodel):

        self.Nparams = 2
        Ncoef = 3   # number of atmospheric coefficients
        self.f = F(Ncoef, watermodel, self.Nparams)

    cdef loop(self, float [:,:,:] Rprime,
              float [:,:] logchl,
              float [:,:,:,:] A,
              float [:,:,:,:] pA,
              float [:,:,:] Tmol,
              float [:,:,:] wav,
              float [:,:] sza,
              float [:,:] vza,
              float [:,:] raa
              ):
        '''
        cython method which does the main pixel loop
        '''

        cdef int Nb = Rprime.shape[0]
        cdef int Nx = Rprime.shape[1]
        cdef int Ny = Rprime.shape[2]
        cdef float [:] x

        print 'processing a block of {}x{}x{}'.format(Nx, Ny, Nb)

        cdef float [:] x0 = np.zeros(self.Nparams, dtype='float32')

        #
        # pixel loop
        #
        for i in range(Nx):
            for j in range(Ny):
                self.f.init(
                        Rprime[:,i,j],
                        A[i,j,:,:], pA[i,j,:,:],
                        Tmol[:,i,j],
                        wav[:,i,j],
                        sza[i,j], vza[i,j], raa[i,j])
                x = self.f.minimize(x0, maxiter=20)
                logchl[i,j] = x[0]


    def minimize(self, block, params):
        '''
        Call minimization code for a block
        (def method visible from python code)
        '''
        # calculate the atmospheric inversion coefficients
        A = atm_func(block, params)
        pA = pseudoinverse(A)

        print block.size, block.sza.shape
        block.logchl = np.zeros(block.size, dtype='float32')

        self.loop(block.Rprime, block.logchl, A, pA, block.Tmol,
                block.wavelen, block.sza, block.vza, block.raa)


