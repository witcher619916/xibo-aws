# Xibo Digital Signage CMS — Self-Hosted on AWS (Terraform PoC)

A fully self-hosted, Infrastructure-as-Code deployment of [Xibo](https://xibosignage.com/) — an open-source digital signage CMS — built as a personal proof of concept to explore self-hosted alternatives to commercial signage platforms.

This started as an investigation into a Power BI integration issue with a commercial signage tool, and turned into a hands-on project to apply and demonstrate Infrastructure-as-Code, cloud networking, and security practices using Terraform on AWS.

---

## What this deploys

- **Xibo CMS**, running via Docker Compose, provisioned automatically at boot via a `user_data` script (Docker install, config generation, container startup — no manual steps)
- **Private-only networking** — the CMS is not reachable from the public internet under any circumstance
- **Zero open inbound ports** — no SSH, no RDP. All administrative access goes through AWS Systems Manager (Session Manager for shell access, Fleet Manager for browser-based RDP), authenticated via IAM roles with temporary, auto-rotating credentials
- **TLS via an internal Application Load Balancer**, using a free, auto-renewing AWS Certificate Manager certificate — HTTPS with a real domain, terminated at the ALB
- **A Windows test instance** running the Xibo Player app, used to validate that a client can actually register with and display content from the CMS
- **DNS managed via Terraform** using the Cloudflare provider — the CNAME record pointing at the load balancer is generated dynamically from the ALB's resource attributes, so it stays correct even if the load balancer is destroyed and recreated

---

## Security model

- Both EC2 instances have public IPs (needed only for *outbound* internet access — package/container downloads via the Internet Gateway) but accept **zero inbound traffic from `0.0.0.0/0`**.
- Administrative access uses **IAM instance profiles + AWS Systems Manager** — no static SSH keys, no open port 22/3389. All sessions are outbound-initiated from the instance.
- The CMS's HTTP port is scoped to **only the ALB's security group** as a source — not the whole VPC.
- The ALB is **internal** — it has no public IP. Its DNS name is publicly resolvable (this is normal for any AWS-managed DNS name), but the addresses it resolves to are private and unreachable from outside the VPC.
- TLS termination happens at the ALB; the backend instance only ever speaks plain HTTP internally.

---

## Tech stack

- **Terraform** (AWS provider + Cloudflare provider)
- **AWS**: VPC, EC2, Application Load Balancer, ACM, IAM, Systems Manager
- **Cloudflare**: DNS (CNAME managed via Terraform, integrated with the ALB's dynamic DNS name)
- **Xibo CMS**: Dockerized, provisioned via a bootstrapping `user_data` script (Docker install, container config, secrets generation via `openssl`)
