# sbchooser

## How upstream finds things (6 steps)

**Step 1: Load PE**  
Read PE paths from CLI or stdin. For each path: open file, mmap it, validate DOS/PE headers and security directory.

**Step 2: Parse PE**  
For each loaded PE: walk the security directory, parse each PKCS#7 signature and cert chain; compute Authenticode image hashes (SHA256, SHA384, SHA512).

**Step 3: Parse DB**  
Load db and dbx from file (`-d`/`-x`) or EFI vars. Walk each store and build in-memory lists of certs and hashes (SHA1/SHA256/SHA384/SHA512).

**Step 4: Declare PE as trusted**  
For each PE: compare its image hashes to dbx then db (revoked/trusted by hash); compare each signature’s certs to dbx then db (revoked/trusted by cert); set secbits from weakest trusted cert in the chain.

**Step 5: Order multiple PEs**  
Sort all PEs with `pe_cmp`: prefer non-revoked, then hash-trusted, then higher secbits, then cert validity, then filename.

**Step 6: Print winner and sorted list**  
Walk the sorted list; for each PE print path (and with `--explain`, the trust/revocation rationale). Revoked or untrusted PEs are skipped in the list.

---

## Feature comparison (sbchooser-dev vs upstream)

| Feature | sbchooser-dev (ours) | Upstream (efivar sbchooser) |
|--------|----------------------|-----------------------------|
| **db source** | `-d` file only; fallback EFI var | `-d` file; `-s` system db; `-D` no system db |
| **dbx source** | `-x` file only; fallback EFI var | `-x` file; `-S` system dbx; `-X` no system dbx |
| **Input** | CLI args only (PE paths) | CLI args; `-i`; stdin (list of paths) |
| **Trust by image hash** | No | Yes (SHA256/SHA384/SHA512 vs db/dbx) |
| **Trust by cert** | Yes (cert SHA1 in db/dbx) | Yes (cert in db/dbx, issuer/same cert) |
| **Scoring** | Weighted: algo + keysize + expiry + vendor (0–100 each) | secbits = min(md_secbits, pk_secbits) |
| **Output** | One “Best: &lt;file&gt;” + per-file verdict | Sorted list of all trusted PEs (best first) |
| **--explain** | No | Yes (prints rationale per PE) |
| **--first-sig-only** | No | Yes |
| **--verbose / -v** | Yes | Yes |
| **--debug / -D** | Yes (dev); -D = debug | No (-D = no-system-db) |
| **PE parsing** | load_pe, pe_get_pkcs7, pkcs7_find_certs/next_cert | load_pe, parse_sigs, add_one_sig, parse_pkcs7, generate_authenticode |
| **secdb use** | Iterate ESLs, match cert SHA1 | parse_secdb_info → add_cert/add_digest (certs + hashes) |
| **Extra modules** | sbchooser-sha1, sbchooser-sig, sbchooser-score | sbchooser-x509, authenticode (image hash) |

---

## Upstream flow summary (functions)

| # | Function(s) | File | What it does | Why needed |
|---|-------------|------|--------------|------------|
| 1 | `main` | sbchooser.c | Parses options (-d/-x db/dbx, -i inputs, -f first-sig-only, --explain), creates `efi_secdb_t` for db/dbx, then loads inputs. | Entry point; wires db/dbx sources and PE inputs before any trust evaluation. |
| 2 | `load_secdb_from_file`, `load_secdb_from_var` | sbchooser-db.c | Loads UEFI security database (db or dbx) from a file or from EFI variable; calls `efi_secdb_parse`. | Supplies trusted (db) and revoked (dbx) certs/hashes for later PE trust checks. |
| 3 | `parse_secdb_info` → `parse_one_secdb_cert` → `add_cert` / `add_digest` | sbchooser-db.c | Visits db then dbx via `efi_secdb_visit_entries`; for each entry adds X509 cert (add_cert + `elaborate_x509_info`) or digest to ctx. | Builds in-memory lists of db/dbx certs and hashes so PEs can be checked against them. |
| 4 | `add_one_pe_to_ctx` → `load_pe` → `add_file_to_ctx` | sbchooser.c, sbchooser-pe.c | For each input path: loads PE (map, validate headers, set sec_dir), then appends to ctx->files. | Collects all candidate PE binaries and validates basic PE structure before scoring. |
| 5 | `load_pe` → `parse_sigs` → `add_one_sig` → `parse_pkcs7` → `add_one_cert` | sbchooser-pe.c | Parses PE security directory; for each WIN_CERT_TYPE_PKCS_SIGNED_DATA parses PKCS#7, extracts signer certs, calls `elaborate_x509_info` and `cert_sec_cmp` for “worst” cert. | Extracts Authenticode signatures and cert chains so each PE can be matched to db/dbx certs and given a strength (secbits). |
| 6 | `generate_authenticode` → `generate_authenticode_begin` / `generate_authenticode_digest` / `generate_authenticode_final` | authenticode.c | Computes SHA256, SHA384, SHA512 image hashes over PE (headers + sections, excluding cert table) and stores in pe_file_t. | Produces image hashes so PEs can be matched to db/dbx hash entries (trust/revocation by hash). |
| 7 | `update_pe_security` → `check_dbx_hashes`, `check_db_hashes` → `check_secdb_hash` | sbchooser-pe.c | Compares pe’s sha256/sha384/sha512 to ctx dbx digests (sets *_revoked) and db digests (sets *_trusted). | Marks PE as revoked/trusted by hash per UEFI Secure Boot (dbx wins over db). |
| 8 | `update_pe_security` → `update_sig_trust` → `update_cert_trust` → `get_revocation`, `get_authorization` | sbchooser-pe.c | For each sig cert: checks dbx (get_revocation via `is_same_cert`/`is_issuing_cert`), then db (get_authorization); sets cert/sig trusted/revoked and rationale. | Decides if each signature is trusted or revoked by cert (not just hash) so secbits and output order are correct. |
| 9 | `update_pe_security` (secbits aggregation) | sbchooser-pe.c | After all sigs: takes minimum of lowest_md_secbits and lowest_pk_secbits across trusted sigs; sets pe->secbits and pe->rationale. | Single “strength” value per PE for sorting; respects --first-sig-only by breaking after first sig when set. |
| 10 | `pe_cmp` → `get_highest_hash_secbits`, `compare_validities` | sbchooser-pe.c | qsort comparator: prefer non-revoked, then hash-trusted over not, then higher hash secbits, then higher pe->secbits, then later expiry / earlier not_before, else strcmp filename. | Orders PEs so the “best” secure-boot choice is first; main loop prints in this order and uses `is_revoked_by_hash`/`is_trusted_by_hash` for --explain and filtering. |

---

## ASCII overview

```
    ┌─────────────┐     ┌─────────────┐
    │  db / dbx   │     │  PE paths   │
    └──────┬──────┘     └──────┬──────┘
           │                   │
           ▼                   │
    ┌─────────────┐            │
    │ 1. Load     │            │
    │    rules    │            │
    └──────┬──────┘            │
           ▼                   ▼
    ┌─────────────┐     ┌─────────────┐
    │ 2. Load PEs │     │ (sigs+hash) │
    └──────┬──────┘     └──────┬──────┘
           └─────────┬─────────┘
                     ▼
              ┌─────────────┐
              │ 3. Score    │
              │ (db/dbx)    │
              └──────┬──────┘
                     ▼
              ┌─────────────┐
              │ 4. Sort &   │
              │    print    │
              └─────────────┘
```

## Big picture

```mermaid
flowchart LR
    A[db/dbx] --> B[Load rules]
    B --> C[Parse certs + hashes]
    C --> D[Load PEs]
    D --> E[Score each PE]
    E --> F[Sort: best first]
    F --> G[Print list]
    H[PE paths] --> D
```

## Block diagram

```mermaid
flowchart TB
    START([run sbchooser]) --> S1[1. Load rules: db/dbx → certs + hashes]
    S1 --> S2[2. Load PEs: parse sigs, hash image]
    S2 --> S3[3. Score: hash match, cert match, secbits]
    S3 --> S4[4. Sort & print: best first]
    S4 --> END([done])
```

## Function flow

```mermaid
flowchart TB
    subgraph S1["1. Load rules"]
        load_secdb_from_file
        load_secdb_from_var
        parse_secdb_info
    end
    subgraph S2["2. Load PEs"]
        add_one_pe_to_ctx
        load_pe
        parse_sigs
        generate_authenticode
    end
    subgraph S3["3. Score"]
        update_pe_security
        check_dbx_hashes
        check_db_hashes
        update_sig_trust
        update_cert_trust
    end
    subgraph S4["4. Sort & print"]
        pe_cmp
    end

    load_secdb_from_file --> parse_secdb_info
    load_secdb_from_var --> parse_secdb_info
    parse_secdb_info --> add_one_pe_to_ctx
    add_one_pe_to_ctx --> load_pe
    load_pe --> parse_sigs
    load_pe --> generate_authenticode
    parse_sigs --> add_one_pe_to_ctx
    generate_authenticode --> add_one_pe_to_ctx
    add_one_pe_to_ctx --> update_pe_security
    update_pe_security --> check_dbx_hashes
    update_pe_security --> check_db_hashes
    update_pe_security --> update_sig_trust
    update_sig_trust --> update_cert_trust
    update_cert_trust --> pe_cmp
    check_dbx_hashes --> pe_cmp
    check_db_hashes --> pe_cmp
```

## Data flow

```mermaid
flowchart LR
    subgraph S1["1. Load rules"]
        DB[db]
        DBX[dbx]
        CERTS[certs + digests]
        DB --> CERTS
        DBX --> CERTS
    end
    subgraph S2["2. Load PEs"]
        PE[PE files]
        SIGS[sigs + hashes]
        PE --> SIGS
    end
    subgraph S3["3. Score"]
        HASH[hash match]
        CERT[cert match]
        SECBITS[secbits]
        CERTS --> HASH
        SIGS --> HASH
        HASH --> CERT
        CERT --> SECBITS
    end
    subgraph S4["4. Sort & print"]
        OUT[ordered list]
        SECBITS --> OUT
    end
    S1 --> S2
    S2 --> S3
    S3 --> S4
```

## One-page overview

```mermaid
flowchart TB
    subgraph INPUTS
        I1["db (who we trust)"]
        I2["dbx (who we revoke)"]
        I3["PE binaries to compare"]
    end

    subgraph STEP1["Step 1: Load rules"]
        L1[load_secdb_from_file / _from_var]
        L2[parse_secdb_info]
    end

    subgraph STEP2["Step 2: Load binaries"]
        L3[load_pe]
        L4[parse_sigs]
        L5[generate_authenticode]
    end

    subgraph STEP3["Step 3: Score"]
        S1[check_dbx_hashes / check_db_hashes]
        S2[update_sig_trust → update_cert_trust]
        S3[secbits]
    end

    subgraph STEP4["Step 4: Order & print"]
        O1[qsort with pe_cmp]
        O2[print paths]
    end

    I1 --> L1
    I2 --> L1
    I3 --> L3
    L1 --> L2
    L2 --> S1
    L3 --> L4
    L4 --> L5
    L5 --> S1
    S1 --> S2
    S2 --> S3
    S3 --> O1
    O1 --> O2
```
