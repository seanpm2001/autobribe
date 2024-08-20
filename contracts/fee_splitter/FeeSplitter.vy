# pragma version ~=0.4.0

"""
@title FeeSplitter
TODO update this to reflect module separation
@notice A contract that collects fees from multiple crvUSD controllers
in a single transaction and distributes them according to some weights.
@license Copyright (c) Curve.Fi, 2020-2024 - all rights reserved
@author curve.fi
@custom:security security@curve.fi
"""

from ethereum.ercs import IERC20
from ethereum.ercs import IERC165

import DynamicWeight
import ControllerMulticlaim as multiclaim

from snekmate.auth import ownable

initializes: multiclaim
initializes: ownable
exports: (ownable.__interface__, multiclaim.__interface__)

event SetWeights:
    distribution_weight: uint256

event SetReceivers: pass

struct Receiver:
    addr: address
    weight: uint256

version: public(constant(String[8])) = "0.1.0" # no guarantees on abi stability

# maximum number of splits
MAX_RECEIVERS: constant(uint256) = 100
# maximum basis points (100%)
MAX_BPS: constant(uint256) = 10_000
# TODO placeholder
DYNAMIC_WEIGHT_EIP165_ID: constant(bytes4) = 0x12431234

# receiver logic
receivers: public(DynArray[Receiver, MAX_RECEIVERS])

crvusd: immutable(IERC20)

@deploy
def __init__(_crvusd: IERC20, _factory: multiclaim.ControllerFactory, receivers: DynArray[Receiver, MAX_RECEIVERS], owner: address):
    """
    @notice Contract constructor
    @param _crvusd The address of the crvUSD token contract
    @param _factory The address of the crvUSD controller factory
    @param receivers The list of receivers (address, weight, dynamic).
        Last item in the list is the excess receiver by default.
    @param owner The address of the contract owner
    """
    assert _crvusd.address != empty(address), "zeroaddr: crvusd"
    assert owner != empty(address), "zeroaddr: owner"

    ownable.__init__()
    ownable._transfer_ownership(owner)
    multiclaim.__init__(_factory)

    # setting immutables
    crvusd = _crvusd

    # set the receivers
    self._set_receivers(receivers)


def _is_dynamic(addr: address) -> bool:
    """
    @notice Check if the address supports the dynamic weight interface
    @param addr The address to check
    @return True if the address supports the dynamic weight interface
    """
    success: bool = False
    response: Bytes[32] = b""
    success, response = raw_call(
        addr,
        abi_encode(DYNAMIC_WEIGHT_EIP165_ID, method_id=method_id("supportsInterface(bytes4)")),
        max_outsize=32,
        is_static_call=True,
        revert_on_failure=False
    )
    return success and convert(response, bool) or len(response) > 32

def _set_receivers(receivers: DynArray[Receiver, MAX_RECEIVERS]):
    assert len(receivers) > 0, "receivers: empty"
    total_weight: uint256 = 0
    for r: Receiver in receivers:
        assert r.addr != empty(address), "zeroaddr: receivers"
        assert r.weight > 0 and r.weight <= MAX_BPS, "receivers: invalid weight"
        total_weight += r.weight
    assert total_weight == MAX_BPS, "receivers: total weight != MAX_BPS"

    self.receivers = receivers

    log SetReceivers()


def is_excess_receiver(i: uint256) -> bool:
    # the excess receiver is always the last one
    return i == len(self.receivers) - 1

def compute_weight(receiver: Receiver, current_excess: uint256) -> (uint256, uint256):
    if not self._is_dynamic(receiver.addr):
        return receiver.weight, current_excess

    dynamic_weight: uint256 = staticcall DynamicWeight(receiver.addr).weight()

    # weight acts as a cap to the dynamic weight
    if dynamic_weight < receiver.weight:
        return dynamic_weight, current_excess + receiver.weight - dynamic_weight

    # if ended up here, the dynamic weight is greater or equal to the weight
    return receiver.weight, current_excess


@nonreentrant
@external
def dispatch_fees(controllers: DynArray[multiclaim.Controller, multiclaim.MAX_CONTROLLERS]=[]):
    """
    @notice Claim fees from all controllers and distribute them
    @param controllers The list of controllers to claim fees from (default: all)
    @dev Splits and transfers the balance according to the receivers weights
    """

    multiclaim.claim_controller_fees(controllers)

    balance: uint256 = staticcall crvusd.balanceOf(self)

    total_excess: uint256 = 0

    # by iterating over the receivers, rather than the indices,
    # we avoid an oob check at every iteration.
    i: uint256 = 0
    for r: Receiver in self.receivers:
        weight: uint256 = 0
        weight, total_excess = self.compute_weight(r, total_excess)

        # if the receiver is the excess receiver,
        # add the excess to the weight.
        if self.is_excess_receiver(i):
            weight += total_excess

        extcall crvusd.transfer(r.addr, balance * weight // MAX_BPS)
        i += 1


@external
def set_receivers(receivers: DynArray[Receiver, MAX_RECEIVERS]):
    """
    @notice Set the receivers
    @param receivers The new receivers
    """
    ownable._check_owner()

    self._set_receivers(receivers)


@view
@external
def n_receivers() -> uint256:
    """
    @notice Get the number of receivers
    @return The number of receivers
    """
    return len(self.receivers)
