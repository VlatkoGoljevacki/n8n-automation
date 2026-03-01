# Regression Testing Plan (Deferred)

**Status**: Planned — pick up after main flow is stable.

## Approach: Option 3 — Test Workflow in n8n

Create a dedicated `WF-TEST: Regression Suite` workflow that runs inside n8n:

```
Manual Trigger → Load Test Fixtures (Code) → SplitInBatches →
  Execute WF-03 with fixture → Compare Output (Code) →
  Execute WF-04 with fixture → Compare Output (Code) →
  Report Results (Code) → Log/Email
```

## How It Works

1. **Fixtures**: Hardcoded JSON in Code nodes (or loaded from files) with known-good inputs and expected outputs
2. **Execution**: Calls each sub-workflow via Execute Workflow node with the test fixtures
3. **Comparison**: Code nodes compare actual output to expected output field-by-field
4. **Reporting**: Summarize pass/fail per sub-workflow, flag mismatches

## Test Cases to Cover

### WF-03: XLSX Parser
- Standard headers (rule-based path) → verify correct column mapping
- Non-standard headers (AI fallback path) → verify AI produces same canonical format
- Empty spreadsheet → verify graceful error
- Missing quantity column → verify fallback to AI

### WF-04: Article Validator
- All valid drug codes → verify all lines validated
- Mixed valid/invalid codes → verify correct split
- Fuzzy name matching → verify match quality

### WF-05: Approval Gate
- Form submitted with Approve → verify approved=true output
- Form submitted with Reject → verify rejected=true output
- Timeout → verify auto-reject

## When to Run

- Before deploying changes to any sub-workflow
- After updating column detection patterns
- After changing LLM model or prompt
