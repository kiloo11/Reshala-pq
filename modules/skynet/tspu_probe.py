#!/usr/bin/env python3
# ============================================================ #
# ==     RIPE ATLAS: ПРОБА ДОСТУПНОСТИ IP ИЗ СЕТЕЙ РФ        == #
# ============================================================ #
#
# Портировано из публичного скрипта censorcheck.tlab.pw
# (автор: Nikola Tesla, https://t.me/tracerlab) - тот же метод измерения
# (RIPE Atlas, sslcert-проба по ASN российских операторов), но с
# СОБСТСТВЕННЫМ RIPE Atlas API-ключом пользователя, а не общим ключом
# автора скрипта (он сам просит не использовать его ключ в сторонних
# проектах - см. docs/... или комментарий в самом censorcheck.sh).
#
# Использование: tspu_probe.py <api_key> <target_ip> <sni>
# Печатает в stdout:
#   OK <total> <success> <blocked>          - измерение прошло
#   BLOCKED_ASN <asn1>:<n1> <asn2>:<n2> ...  - опционально, вторая строка
#   ERROR <причина>                          - измерение не удалось

import sys
import json
import time
import urllib.request

RIPE_PROBE_ASNS = [
    (3, 12389),
    (5, 8402),
    (5, 25513),
    (3, 8359),
    (3, 3216),
    (2, 20485),
    (1, 25490),
    (1, 43727),
    (4, 12714),
    (2, 34757),
    (2, 29124),
    (2, 12768),
]


def main():
    if len(sys.argv) < 4:
        print("ERROR BAD_ARGS")
        return

    api_key = sys.argv[1]
    target_ip = sys.argv[2]
    sni = sys.argv[3]

    url = "https://atlas.ripe.net/api/v2/measurements/"
    data = {
        "definitions": [{
            "target": target_ip,
            "description": "Reshala TSPU Check",
            "type": "sslcert",
            "port": 443,
            "hostname": sni,
            "af": 4,
        }],
        "probes": [
            {"requested": n, "type": "asn", "value": asn, "tags": {"include": ["system-ipv4-works"]}}
            for (n, asn) in RIPE_PROBE_ASNS
        ],
        "is_oneoff": True,
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Key {api_key}"},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            resp_data = json.loads(response.read().decode())
            msm_id = resp_data["measurements"][0]
    except Exception as e:
        print(f"ERROR API_FAIL:{type(e).__name__}")
        return

    total_requested = sum(n for (n, _) in RIPE_PROBE_ASNS)
    results_url = f"https://atlas.ripe.net/api/v2/measurements/{msm_id}/results/"
    results = []

    for _ in range(25):
        time.sleep(2)
        try:
            with urllib.request.urlopen(results_url, timeout=15) as response:
                results = json.loads(response.read().decode())
                if len(results) >= total_requested:
                    break
        except Exception:
            pass

    if not results:
        print("ERROR NO_DATA")
        return

    blocked = 0
    blocked_prb_ids = []
    for probe in results:
        if "cert" in probe or "method" in probe or "alert" in probe:
            pass
        else:
            blocked += 1
            prb_id = probe.get("prb_id")
            if prb_id:
                blocked_prb_ids.append(prb_id)

    total = len(results)
    success = total - blocked
    print(f"OK {total} {success} {blocked}")

    if blocked_prb_ids:
        blocked_asns = {}
        try:
            ids_str = ",".join(str(p) for p in blocked_prb_ids)
            probes_url = f"https://atlas.ripe.net/api/v2/probes/?id__in={ids_str}&fields=id,asn_v4"
            with urllib.request.urlopen(probes_url, timeout=15) as response:
                probe_info = json.loads(response.read().decode())
                for p in probe_info.get("results", []):
                    asn = p.get("asn_v4")
                    if asn:
                        blocked_asns[asn] = blocked_asns.get(asn, 0) + 1
        except Exception:
            pass

        if blocked_asns:
            parts = " ".join(f"{asn}:{cnt}" for asn, cnt in blocked_asns.items())
            print(f"BLOCKED_ASN {parts}")


if __name__ == "__main__":
    main()
