#!/usr/bin/env node
/**
 * Refactor WF-01: Replace customer cache static data with DataTable lookups.
 *
 * Removes: Check Customer Cache, Customers Cached?, Fetch Customers API, Store Customer Cache
 * Adds: Lookup Delivery Places (DT GET), Has Missing? (IF), WF-07 call, Re-lookup (DT GET),
 *       Build Customer Lookup (Code - merges results)
 *
 * New flow after ERP token section:
 *   ... Token path ... → Extract Email Metadata → WF-02 → Sender Valid? → Has Attachments?
 *     → Prepare Parser Input → WF-03 → Parse Succeeded?
 *       [yes] → Lookup Delivery Places → Build Customer Lookup → Has Missing?
 *         [no]  → Prepare Validator Input → ...
 *         [yes] → WF-07: Refresh Customers → Re-lookup Delivery Places → Build Customer Lookup After Refresh → Prepare Validator Input
 *       [no]  → Parse Failed
 */

const fs = require('fs');
const path = require('path');

const WF_PATH = path.join(__dirname, '..', 'workflows', 'medika_preorder_01_orchestrator.json');
const CUSTOMERS_DT_ID = 'StBs20UpNqyvqo9t';
const PROJECT_ID = 'hrbLY7WdX4PPEv0o';
const WF07_ID = 'Ca6USlpwwebcje0c';

const wf = JSON.parse(fs.readFileSync(WF_PATH, 'utf-8'));

// ─── Helpers ────────────────────────────────────────────────────────────────

function findNode(name) {
  return wf.nodes.find(n => n.name === name);
}

function removeNode(name) {
  const idx = wf.nodes.findIndex(n => n.name === name);
  if (idx === -1) throw new Error(`Node "${name}" not found`);
  wf.nodes.splice(idx, 1);
  delete wf.connections[name];
  // Also remove any connections TO this node
  for (const [src, conn] of Object.entries(wf.connections)) {
    for (const outputs of conn.main || []) {
      const toRemove = [];
      for (let i = 0; i < outputs.length; i++) {
        if (outputs[i].node === name) toRemove.push(i);
      }
      for (const i of toRemove.reverse()) outputs.splice(i, 1);
    }
  }
  console.log(`  Removed node: ${name}`);
}

function makeDataTableRef() {
  return {
    __rl: true,
    value: CUSTOMERS_DT_ID,
    mode: 'list',
    cachedResultName: 'Customers',
    cachedResultUrl: `/projects/${PROJECT_ID}/datatables/${CUSTOMERS_DT_ID}`,
  };
}

function conn(target) {
  return { node: target, type: 'main', index: 0 };
}

// ─── 1. Remove old customer cache nodes ─────────────────────────────────────

console.log('Step 1: Removing old customer cache nodes...');
const nodesToRemove = [
  'Check Customer Cache',
  'Customers Cached?',
  'Fetch Customers API',
  'Store Customer Cache',
];
for (const name of nodesToRemove) removeNode(name);

// ─── 2. Rewire ERP token paths to skip directly to Extract Email Metadata ───

console.log('\nStep 2: Rewiring ERP token paths...');

// Token Valid? [yes] (index 0) was → Check Customer Cache, now → Extract Email Metadata
if (wf.connections['Token Valid?']) {
  wf.connections['Token Valid?'].main[0] = [conn('Extract Email Metadata')];
  console.log('  Token Valid? [yes] → Extract Email Metadata');
}

// Store ERP Token → was Check Customer Cache, now → Extract Email Metadata
if (wf.connections['Store ERP Token']) {
  wf.connections['Store ERP Token'].main[0] = [conn('Extract Email Metadata')];
  console.log('  Store ERP Token → Extract Email Metadata');
}

// ─── 3. Add new nodes after Parse Succeeded? ───────────────────────────────

console.log('\nStep 3: Adding new DataTable lookup nodes...');

const parseSucceededNode = findNode('Parse Succeeded?');
const prepValidatorNode = findNode('Prepare Validator Input');
if (!parseSucceededNode || !prepValidatorNode) {
  throw new Error('Required nodes not found');
}

// Base X position: after Parse Succeeded on the [yes] path
const baseX = prepValidatorNode.position[0];
const baseY = prepValidatorNode.position[1];

// 3a. "Extract Order Delivery IDs" — Code node that extracts unique delivery place IDs from parsed order
const extractIdsNode = {
  parameters: {
    mode: 'runOnceForAllItems',
    jsCode: [
      '// Extract unique delivery place IDs from parsed order lines',
      'const parseResult = $input.first().json;',
      'const orderLines = parseResult.orderLines || [];',
      '',
      '// Collect unique delivery place IDs (pharmacyId field)',
      'const ids = [...new Set(orderLines.map(l => l.pharmacyId).filter(Boolean))];',
      '',
      'return [{ json: { ...parseResult, deliveryPlaceIds: ids } }];',
    ].join('\n'),
  },
  type: 'n8n-nodes-base.code',
  typeVersion: 2,
  position: [baseX, baseY],
  id: 'b1000000-0000-4000-8000-000000000080',
  name: 'Extract Order Delivery IDs',
};
wf.nodes.push(extractIdsNode);
console.log('  Added: Extract Order Delivery IDs');

// 3b. "DT: Lookup Delivery Places" — DataTable GET with filter
// Note: DataTable GET returns all rows. We filter in the next Code node.
const dtLookupNode = {
  parameters: {
    operation: 'get',
    dataTableId: makeDataTableRef(),
    limit: 500,
  },
  type: 'n8n-nodes-base.dataTable',
  typeVersion: 1.1,
  position: [baseX + 240, baseY],
  id: 'b1000000-0000-4000-8000-000000000081',
  name: 'DT: Lookup Delivery Places',
};
wf.nodes.push(dtLookupNode);
console.log('  Added: DT: Lookup Delivery Places');

// 3c. "Build Customer Lookup" — Code node that matches DT rows to order IDs, detects missing
const buildLookupNode = {
  parameters: {
    mode: 'runOnceForAllItems',
    jsCode: [
      '// Match DataTable rows to the delivery place IDs from the order',
      "const parseResult = $('Extract Order Delivery IDs').first().json;",
      'const deliveryPlaceIds = parseResult.deliveryPlaceIds || [];',
      '',
      '// Build lookup from DataTable rows',
      "const dtRows = $('DT: Lookup Delivery Places').all();",
      'const deliveryPlaceById = {};',
      'const customerById = {};',
      '',
      'for (const row of dtRows) {',
      '  const r = row.json;',
      '  if (r.deliveryPlaceId) {',
      '    deliveryPlaceById[r.deliveryPlaceId] = {',
      '      customerId: r.customerId,',
      '      customerName: r.customerName,',
      '      name: r.name,',
      '      city: r.city,',
      '      postCode: r.postCode,',
      '      street: r.street',
      '    };',
      '    if (r.customerId && !customerById[r.customerId]) {',
      '      customerById[r.customerId] = {',
      '        name: r.customerName,',
      '        oib: r.oib,',
      '        city: r.city,',
      '        postCode: r.postCode,',
      '        street: r.street',
      '      };',
      '    }',
      '  }',
      '}',
      '',
      '// Check which requested IDs are missing',
      'const missingIds = deliveryPlaceIds.filter(id => !deliveryPlaceById[id]);',
      '',
      'return [{',
      '  json: {',
      '    ...parseResult,',
      '    customerLookup: {',
      '      customerById,',
      '      deliveryPlaceById,',
      '      totalCustomers: Object.keys(customerById).length,',
      '      totalDeliveryPlaces: Object.keys(deliveryPlaceById).length,',
      "      source: 'datatable'",
      '    },',
      '    missingDeliveryPlaceIds: missingIds,',
      '    hasMissing: missingIds.length > 0',
      '  }',
      '}];',
    ].join('\n'),
  },
  type: 'n8n-nodes-base.code',
  typeVersion: 2,
  position: [baseX + 480, baseY],
  id: 'b1000000-0000-4000-8000-000000000082',
  name: 'Build Customer Lookup',
};
wf.nodes.push(buildLookupNode);
console.log('  Added: Build Customer Lookup');

// 3d. "Has Missing?" — IF node
const hasMissingNode = {
  parameters: {
    conditions: {
      options: {
        caseSensitive: true,
        leftValue: '',
        typeValidation: 'strict',
      },
      conditions: [
        {
          id: 'd1000080-0000-4000-8000-000000000001',
          leftValue: '={{ $json.hasMissing }}',
          rightValue: true,
          operator: {
            type: 'boolean',
            operation: 'true',
          },
        },
      ],
      combinator: 'and',
    },
    options: {},
  },
  type: 'n8n-nodes-base.if',
  typeVersion: 2,
  position: [baseX + 720, baseY],
  id: 'b1000000-0000-4000-8000-000000000083',
  name: 'Has Missing?',
};
wf.nodes.push(hasMissingNode);
console.log('  Added: Has Missing?');

// 3e. "WF-07: Refresh Customers" — Execute Workflow node
const refreshNode = {
  parameters: {
    workflowId: {
      __rl: true,
      mode: 'id',
      value: WF07_ID,
    },
    options: {},
  },
  type: 'n8n-nodes-base.executeWorkflow',
  typeVersion: 1.2,
  position: [baseX + 960, baseY + 200],
  id: 'b1000000-0000-4000-8000-000000000084',
  name: 'WF-07: Refresh Customers',
  onError: 'continueRegularOutput',
};
wf.nodes.push(refreshNode);
console.log('  Added: WF-07: Refresh Customers');

// 3f. "Re-lookup Delivery Places" — DataTable GET (after refresh)
const reLookupNode = {
  parameters: {
    operation: 'get',
    dataTableId: makeDataTableRef(),
    limit: 500,
  },
  type: 'n8n-nodes-base.dataTable',
  typeVersion: 1.1,
  position: [baseX + 1200, baseY + 200],
  id: 'b1000000-0000-4000-8000-000000000085',
  name: 'Re-lookup Delivery Places',
};
wf.nodes.push(reLookupNode);
console.log('  Added: Re-lookup Delivery Places');

// 3g. "Rebuild Customer Lookup" — Code node (after refresh, same logic)
const rebuildLookupNode = {
  parameters: {
    mode: 'runOnceForAllItems',
    jsCode: [
      '// Rebuild lookup after WF-07 refresh — same logic as Build Customer Lookup',
      "const parseResult = $('Extract Order Delivery IDs').first().json;",
      'const deliveryPlaceIds = parseResult.deliveryPlaceIds || [];',
      '',
      "const dtRows = $('Re-lookup Delivery Places').all();",
      'const deliveryPlaceById = {};',
      'const customerById = {};',
      '',
      'for (const row of dtRows) {',
      '  const r = row.json;',
      '  if (r.deliveryPlaceId) {',
      '    deliveryPlaceById[r.deliveryPlaceId] = {',
      '      customerId: r.customerId,',
      '      customerName: r.customerName,',
      '      name: r.name,',
      '      city: r.city,',
      '      postCode: r.postCode,',
      '      street: r.street',
      '    };',
      '    if (r.customerId && !customerById[r.customerId]) {',
      '      customerById[r.customerId] = {',
      '        name: r.customerName,',
      '        oib: r.oib,',
      '        city: r.city,',
      '        postCode: r.postCode,',
      '        street: r.street',
      '      };',
      '    }',
      '  }',
      '}',
      '',
      'const missingIds = deliveryPlaceIds.filter(id => !deliveryPlaceById[id]);',
      'if (missingIds.length > 0) {',
      "  console.log('Still missing after refresh: ' + missingIds.join(', '));",
      '}',
      '',
      'return [{',
      '  json: {',
      '    ...parseResult,',
      '    customerLookup: {',
      '      customerById,',
      '      deliveryPlaceById,',
      '      totalCustomers: Object.keys(customerById).length,',
      '      totalDeliveryPlaces: Object.keys(deliveryPlaceById).length,',
      "      source: 'datatable_refreshed'",
      '    },',
      '    missingDeliveryPlaceIds: missingIds,',
      '    hasMissing: missingIds.length > 0',
      '  }',
      '}];',
    ].join('\n'),
  },
  type: 'n8n-nodes-base.code',
  typeVersion: 2,
  position: [baseX + 1440, baseY + 200],
  id: 'b1000000-0000-4000-8000-000000000086',
  name: 'Rebuild Customer Lookup',
};
wf.nodes.push(rebuildLookupNode);
console.log('  Added: Rebuild Customer Lookup');

// ─── 4. Rewrite Prepare Validator Input ─────────────────────────────────────

console.log('\nStep 4: Rewriting Prepare Validator Input...');

prepValidatorNode.parameters.jsCode = [
  '// Prepare input for data validation with customer lookup from DataTable',
  'const lookupResult = $input.first().json;',
  "const emailMeta = $('Extract Email Metadata').first().json;",
  "const parserInput = $('Prepare Parser Input').first().json;",
  "const config = $('Config').first().json;",
  "const erpToken = $('Check ERP Token').first().json.erpToken",
  "  || ($('Store ERP Token').first().json || {}).erpToken;",
  '',
  'return [{',
  '  json: {',
  '    config: config,',
  '    orderLines: lookupResult.orderLines || [],',
  '    lineCount: lookupResult.lineCount || 0,',
  '    senderEmail: emailMeta.senderEmail,',
  '    emailSubject: emailMeta.emailSubject,',
  '    customer: parserInput.customer,',
  '    deliveryPlace: parserInput.deliveryPlace,',
  '    defaultDiscountPerc: parserInput.defaultDiscountPerc,',
  '    customerLookup: lookupResult.customerLookup',
  '  }',
  '}];',
].join('\n');

// Move it to the right to make room for new nodes
prepValidatorNode.position = [baseX + 960, baseY];

console.log('  Rewrote: Prepare Validator Input');

// ─── 5. Rewrite Prepare Submission Input (remove static data token read) ────

console.log('\nStep 5: Simplifying Prepare Submission Input...');

const prepSubmitNode = findNode('Prepare Submission Input');
if (prepSubmitNode) {
  prepSubmitNode.parameters.jsCode = [
    '// Pass approval result to WF-06 (token is handled by WF-06 itself now)',
    'const approvalResult = $input.first().json;',
    "const config = approvalResult.config || $('Config').first().json;",
    '',
    'return [{',
    '  json: {',
    '    ...approvalResult,',
    '    config: config',
    '  }',
    '}];',
  ].join('\n');
  console.log('  Simplified: Prepare Submission Input');
}

// ─── 6. Wire up all new connections ─────────────────────────────────────────

console.log('\nStep 6: Wiring connections...');

// Parse Succeeded? [yes] → Extract Order Delivery IDs (was Prepare Validator Input)
wf.connections['Parse Succeeded?'].main[0] = [conn('Extract Order Delivery IDs')];
console.log('  Parse Succeeded? [yes] → Extract Order Delivery IDs');

// Extract Order Delivery IDs → DT: Lookup Delivery Places
wf.connections['Extract Order Delivery IDs'] = { main: [[conn('DT: Lookup Delivery Places')]] };
console.log('  Extract Order Delivery IDs → DT: Lookup Delivery Places');

// DT: Lookup Delivery Places → Build Customer Lookup
wf.connections['DT: Lookup Delivery Places'] = { main: [[conn('Build Customer Lookup')]] };
console.log('  DT: Lookup Delivery Places → Build Customer Lookup');

// Build Customer Lookup → Has Missing?
wf.connections['Build Customer Lookup'] = { main: [[conn('Has Missing?')]] };
console.log('  Build Customer Lookup → Has Missing?');

// Has Missing? [yes/true = index 0 in n8n IF] → WF-07: Refresh Customers
// Has Missing? [no/false = index 1] → Prepare Validator Input
wf.connections['Has Missing?'] = {
  main: [
    [conn('WF-07: Refresh Customers')],   // true (has missing)
    [conn('Prepare Validator Input')],      // false (all found)
  ],
};
console.log('  Has Missing? [yes] → WF-07: Refresh Customers');
console.log('  Has Missing? [no] → Prepare Validator Input');

// WF-07: Refresh Customers → Re-lookup Delivery Places
wf.connections['WF-07: Refresh Customers'] = { main: [[conn('Re-lookup Delivery Places')]] };
console.log('  WF-07: Refresh Customers → Re-lookup Delivery Places');

// Re-lookup Delivery Places → Rebuild Customer Lookup
wf.connections['Re-lookup Delivery Places'] = { main: [[conn('Rebuild Customer Lookup')]] };
console.log('  Re-lookup Delivery Places → Rebuild Customer Lookup');

// Rebuild Customer Lookup → Prepare Validator Input
wf.connections['Rebuild Customer Lookup'] = { main: [[conn('Prepare Validator Input')]] };
console.log('  Rebuild Customer Lookup → Prepare Validator Input');

// ─── 7. Pass erpToken to WF-07 ─────────────────────────────────────────────
// WF-07 needs an erpToken. We need to ensure it flows through.
// The "Has Missing?" node's input has parseResult which doesn't include erpToken.
// Let's update "Extract Order Delivery IDs" to also carry the erpToken.

console.log('\nStep 7: Ensuring erpToken flows to WF-07...');

extractIdsNode.parameters.jsCode = [
  '// Extract unique delivery place IDs from parsed order lines',
  '// Also carry erpToken for potential WF-07 refresh call',
  'const parseResult = $input.first().json;',
  'const orderLines = parseResult.orderLines || [];',
  '',
  '// Get erpToken from whichever path was taken',
  'let erpToken;',
  'try { erpToken = $("Check ERP Token").first().json.erpToken; } catch(e) {}',
  'if (!erpToken) {',
  '  try { erpToken = $("Store ERP Token").first().json.erpToken; } catch(e) {}',
  '}',
  '',
  '// Collect unique delivery place IDs (pharmacyId field)',
  'const ids = [...new Set(orderLines.map(l => l.pharmacyId).filter(Boolean))];',
  '',
  'return [{ json: { ...parseResult, deliveryPlaceIds: ids, erpToken } }];',
].join('\n');
console.log('  Updated: Extract Order Delivery IDs now carries erpToken');

// ─── Write output ───────────────────────────────────────────────────────────

fs.writeFileSync(WF_PATH, JSON.stringify(wf, null, 2) + '\n');
console.log(`\nWrote: ${WF_PATH}`);
console.log('\nSummary:');
console.log('  Removed: 4 nodes (Check Customer Cache, Customers Cached?, Fetch Customers API, Store Customer Cache)');
console.log('  Added:   7 nodes (Extract IDs, DT Lookup, Build Lookup, Has Missing?, WF-07, Re-lookup, Rebuild)');
console.log('  Rewrote: 2 nodes (Prepare Validator Input, Prepare Submission Input)');
