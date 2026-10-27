#!/usr/bin/env python3
"""Linux 独立合法客户端 H3 适配器；只观测，不改节点/网络/策略。

通过 tailscaled LocalAPI 用真实节点身份发送 disco 往返，并严格核对实际
DERPRegionID。直连、其他区域、多节点歧义均返回 unknown（2）。
接口依据 tailscale v1.104.1 client/local/local.go；实测兼容版本另记证据。
"""
import argparse
import hashlib
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import struct
import sys
import time
import zlib
from typing import NamedTuple
from urllib.parse import urlencode


class Unverified(Exception):
    pass


class ProbeFailed(Exception):
    pass


class Target(NamedTuple):
    region: int
    ip: str
    derp_port: int
    stun_port: int


def match_region(mapping, target):
    region = mapping.get('Regions', {}).get(str(target.region), {})
    nodes = [n for n in region.get('Nodes', []) if not n.get('STUNOnly')]
    if region.get('RegionID') != target.region or len(nodes) != 1:
        raise Unverified('指定 Region 必须只有一个 DERP 节点，避免把其他节点转发当成本节点成功')
    node = nodes[0]
    address = node.get('IPv4') if ipaddress.ip_address(target.ip).version == 4 else node.get('IPv6')
    # 默认生成片段仅含数字IP HostName；精确相同才可替代缺省地址，绝不猜测DNS。
    if not address and node.get('HostName') == target.ip:
        address = target.ip
    if (address != target.ip or (node.get('DERPPort') or 443) != target.derp_port
            or (node.get('STUNPort') or 3478) != target.stun_port):
        raise Unverified('客户端下发的节点地址/端口与请求目标不一致')
    pin = node.get('CertName', '')
    if not re.fullmatch(r'sha256-raw:[0-9a-f]{64}', pin):
        raise Unverified('需要本节点下发的 sha256-raw 自签指纹')
    return pin


def check_peer(status, peer):
    own = status.get('Self') or {}
    if status.get('BackendState') != 'Running' or not own.get('ID'):
        raise Unverified('本地客户端未登录运行')
    if peer in own.get('TailscaleIPs', []):
        raise Unverified('探针对端不能是自身')
    if not any(p.get('ID') and p['ID'] != own['ID'] and peer in p.get('TailscaleIPs', [])
               for p in (status.get('Peer') or {}).values()):
        raise Unverified('指定对端不是当前客户端可见的独立合法节点')


def check_ping(result, target, peer):
    if result.get('Err'):
        raise ProbeFailed('真实节点 ping 返回确认故障')
    if (result.get('DERPRegionID') != target.region or result.get('NodeIP') != peer
            or result.get('IsLocalIP') or result.get('PeerRelay') or result.get('Endpoint')):
        raise Unverified('未观测到指定 Region 的对端往返；可能直连、其他区域或 peer relay')


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__('local-tailscaled.sock', timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def local_api(path, method, endpoint, timeout):
    conn = UnixConnection(path, timeout)
    try:
        conn.request(method, '/localapi/v0/' + endpoint)
        response = conn.getresponse()
        if response.status != 200:
            raise Unverified('tailscaled LocalAPI 不可用/权限不足')
        body = response.read(4 * 1024 * 1024 + 1)
        if len(body) > 4 * 1024 * 1024:
            raise Unverified('LocalAPI 报文过大')
        return json.loads(body)
    finally:
        conn.close()


def live_pin(target, timeout):
    # 自签证书在下一步对照控制面下发的完整DER证书摘要，而非依赖PKI。
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((target.ip, target.derp_port), timeout=timeout) as tcp:
        with context.wrap_socket(tcp, server_hostname=target.ip) as tls:
            return 'sha256-raw:' + hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()


def check_pin(target, expected, timeout):
    if live_pin(target, timeout) != expected:
        raise Unverified('客户端指纹与当前服务证书不一致，控制面传播/切换尚未确认')


def validate_stun(packet, tx):
    if len(packet) < 20:
        raise ProbeFailed('STUN 响应不完整')
    kind, length, cookie = struct.unpack('!HHI', packet[:8])
    if (kind != 0x0101 or cookie != 0x2112a442 or packet[8:20] != tx
            or length % 4 or length != len(packet) - 20):
        raise ProbeFailed('STUN 响应类型/事务/长度不匹配')
    pos, mapped = 20, False
    while pos < len(packet):
        if pos + 4 > len(packet):
            raise ProbeFailed('STUN 属性头不完整')
        attr, size = struct.unpack('!HH', packet[pos:pos+4])
        end = pos + 4 + size
        if end > len(packet) or pos + 4 + ((size + 3) & ~3) > len(packet):
            raise ProbeFailed('STUN 属性不完整')
        value = packet[pos+4:end]
        if attr in (0x0001, 0x0020) and size in (8, 20):
            mapped |= value[0] == 0 and ((value[1] == 1 and size == 8) or (value[1] == 2 and size == 20))
        pos += 4 + ((size + 3) & ~3)
    if not mapped:
        raise ProbeFailed('STUN 响应缺少有效映射地址')


def check_stun(target, timeout):
    tx = os.urandom(12)
    # Tailscale STUN服务要求tailnode SOFTWARE及RFC5389 FINGERPRINT。
    request = struct.pack('!HHI', 1, 20, 0x2112a442) + tx
    request += struct.pack('!HH', 0x8022, 8) + b'tailnode'
    fingerprint = zlib.crc32(request) ^ 0x5354554e
    request += struct.pack('!HHI', 0x8028, 4, fingerprint)
    family = socket.AF_INET6 if ipaddress.ip_address(target.ip).version == 6 else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as udp:
        udp.settimeout(timeout)
        udp.connect((target.ip, target.stun_port))
        udp.send(request)
        try:
            validate_stun(udp.recv(2048), tx)
        except (TimeoutError, ConnectionRefusedError) as err:
            raise ProbeFailed('目标 STUN 没有返回有效响应') from err


def report(target, derp, stun):
    return (f'schema=1\nregion_id={target.region}\nip={target.ip}\nderp_port={target.derp_port}\n'
            f'stun_port={target.stun_port}\nchecked_at={int(time.time())}\n'
            f'derp={"ok" if derp else "failed"}\nstun={"ok" if stun else "failed"}\n')


def run(args):
    target = Target(args.region_id, str(ipaddress.ip_address(args.ip)), args.derp_port, args.stun_port)
    peer = str(ipaddress.ip_address(args.peer_ip))
    if target.region <= 0 or not all(1 <= p <= 65535 for p in target[2:]) or not 0 < args.timeout <= 110:
        raise Unverified('目标参数越界')
    deadline = time.monotonic() + args.timeout
    def remaining():
        left = deadline - time.monotonic()
        if left <= 0:
            raise Unverified('探针总预算已耗尽')
        return left
    def api(method, endpoint):
        return local_api(args.socket, method, endpoint, remaining())
    check_peer(api('GET', 'status'), peer)
    pin = match_region(api('GET', 'derpmap'), target)
    check_pin(target, pin, remaining())
    derp, stun = True, True
    try:
        check_ping(api('POST', 'ping?' + urlencode({'ip': peer, 'type': 'disco'})), target, peer)
    except ProbeFailed:
        derp = False
    try:
        check_stun(target, remaining())
    except ProbeFailed:
        stun = False
    # 检查期间控制面/证书若改变，不把两轮不同身份拼成一次通过。
    if match_region(api('GET', 'derpmap'), target) != pin:
        raise Unverified('检查期间控制面指纹发生变化')
    check_pin(target, pin, remaining())
    print(report(target, derp, stun), end='')
    return 0 if derp and stun else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('region-id', 'derp-port', 'stun-port'):
        parser.add_argument('--' + name, required=True, type=int)
    parser.add_argument('--ip', required=True)
    parser.add_argument('--peer-ip', required=True, help='另一个已授权客户端的 Tailnet IP')
    parser.add_argument('--socket', default='/var/run/tailscale/tailscaled.sock')
    parser.add_argument('--timeout', type=float, default=10)
    args = parser.parse_args()
    try:
        return run(args)
    except (Unverified, OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as err:
        # 不转储LocalAPI原文、节点公钥或策略；stdout留空，让上层明确判unknown。
        print('未验收：' + (str(err) if isinstance(err, Unverified) else type(err).__name__), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
