#!/usr/bin/env python3
"""Strict version-specific nftables backport of Netavark PR #1483.

Run from an unpacked Debian netavark source after quilt add.
Unsupported source layouts fail without writing changes.
"""
import argparse
from pathlib import Path

def once(s, old, new, label):
    n=s.count(old)
    if n!=1:
        raise SystemExit(f"Unexpected source layout: {label}: {n} matches (need 1)")
    return s.replace(old,new,1)

def patch(source, family):
    if "const DNAT_MASK: u32" in source:
        raise SystemExit("Already patched")
    source=once(source,"const MASK: u32 = 0x2000;",
      "const MASK: u32 = 0x2000;\nconst DNAT_MASK: u32 = 0x1000;","constant")
    if family=="1.14":
        forward="""        // Permit published-port DNAT before inter-bridge isolation (PR #1483).
        let match_dnat_mask = |r: &schema::Rule| -> bool {
            r.expr.iter().any(|statement| match statement {
                stmt::Statement::Match(m) => {
                    matches!(&m.right, expr::Expression::Number(n) if *n == DNAT_MASK)
                }
                _ => false,
            })
        };
        if get_matching_rules_in_chain(&existing_rules, FORWARDCHAIN, match_dnat_mask).is_empty() {
            batch.add(make_rule(
                FORWARDCHAIN,
                vec![
                    stmt::Statement::Match(stmt::Match {
                        left: expr::Expression::BinaryOperation(expr::BinaryOperation::AND(
                            Box::new(expr::Expression::Named(expr::NamedExpression::CT(expr::CT {
                                key: "mark".to_string(), family: None, dir: None,
                            }))),
                            Box::new(expr::Expression::Number(DNAT_MASK)),
                        )),
                        right: expr::Expression::Number(DNAT_MASK),
                        op: stmt::Operator::EQ,
                    }),
                    stmt::Statement::Accept(None),
                ],
            ));
        }

"""
        mark="""        statements.push(stmt::Statement::Mangle(stmt::Mangle {
            key: expr::Expression::Named(expr::NamedExpression::CT(expr::CT {
                key: "mark".to_string(), family: None, dir: None,
            })),
            value: expr::Expression::BinaryOperation(expr::BinaryOperation::OR(
                Box::new(expr::Expression::Named(expr::NamedExpression::Meta(expr::Meta {
                    key: expr::MetaKey::Mark,
                }))),
                Box::new(expr::Expression::Number(DNAT_MASK)),
            )),
        }));
"""
    elif family in ("1.17","2.0"):
        forward="""        // Permit published-port DNAT before inter-bridge isolation (PR #1483).
        let match_dnat_mask = |r: &schema::Rule| -> bool {
            r.expr.iter().any(|statement| match statement {
                stmt::Statement::Match(m) => {
                    matches!(&m.right, expr::Expression::Number(n) if *n == DNAT_MASK)
                }
                _ => false,
            })
        };
        if get_matching_rules_in_chain(&existing_rules, FORWARDCHAIN, match_dnat_mask).is_empty() {
            batch.add(make_rule(
                Cow::Borrowed(FORWARDCHAIN),
                Cow::Owned(vec![
                    stmt::Statement::Match(stmt::Match {
                        left: expr::Expression::BinaryOperation(Box::new(expr::BinaryOperation::AND(
                            expr::Expression::Named(expr::NamedExpression::CT(expr::CT {
                                key: Cow::Borrowed("mark"), family: None, dir: None,
                            })),
                            expr::Expression::Number(DNAT_MASK),
                        ))),
                        right: expr::Expression::Number(DNAT_MASK),
                        op: stmt::Operator::EQ,
                    }),
                    stmt::Statement::Accept(None),
                ]),
            ));
        }

"""
        mark="""        statements.push(stmt::Statement::Mangle(stmt::Mangle {
            key: expr::Expression::Named(expr::NamedExpression::CT(expr::CT {
                key: Cow::Borrowed("mark"), family: None, dir: None,
            })),
            value: expr::Expression::BinaryOperation(Box::new(expr::BinaryOperation::OR(vec![
                expr::Expression::Named(expr::NamedExpression::Meta(expr::Meta {
                    key: expr::MetaKey::Mark,
                })),
                expr::Expression::Number(DNAT_MASK),
            ]))),
        }));
"""
    else:
        raise SystemExit(f"Unsupported source family: {family}")
    source=once(source,"        // Forward chain: jump NETAVARK-ISOLATION-1\n",
         forward+"        // Forward chain: jump NETAVARK-ISOLATION-1\n","forward chain")
    start="fn get_dnat_port_rules"
    end="fn get_dnat_rules_for_addr_family"
    if source.count(start)!=1 or source.count(end)!=1:
        raise SystemExit("Unsupported DNAT function layout")
    prefix, rest=source.split(start,1)
    func, suffix=rest.split(end,1)
    func=once(func,"        statements.push(stmt::Statement::DNAT(Some(stmt::NAT {",
         mark+"        statements.push(stmt::Statement::DNAT(Some(stmt::NAT {","DNAT marking")
    return prefix+start+func+end+suffix

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--family", required=True, choices=["1.14","1.17","2.0"])
    family=parser.parse_args().family
    path=Path("src/firewall/nft.rs")
    if not path.is_file() or not Path("debian/patches/series").is_file():
        raise SystemExit("Run inside an extracted Debian Netavark quilt source")
    before=path.read_text()
    after=patch(before,family)
    path.write_text(after)
    print(f"Backported PR #1483 to Netavark {family}; review generated quilt patch")
if __name__=="__main__":
    main()
