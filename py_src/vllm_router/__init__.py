# a lightweihgt wrapper on router with argument type and comments
# no wrapper on policy type => direct export
from vllm_router.router import Router
from vllm_router.version import __version__
from vllm_router_rs import PolicyType

__all__ = ["Router", "PolicyType", "__version__"]
