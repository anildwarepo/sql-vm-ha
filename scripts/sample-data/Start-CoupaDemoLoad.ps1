<#
.SYNOPSIS
    Generates continuous OLTP load against the Coupa demo databases.

.DESCRIPTION
    Runs a pool of worker threads that execute a weighted mix of realistic procure-to-pay
    operations until the duration elapses or you press Ctrl+C:

      Reads   - supplier scorecard, spend by commodity, budget vs spend, monthly trend, catalog search,
                PO detail, approval queue, invoice aging, supplier statement, expense analytics.
                A share of reads goes directly to the readable secondary (ApplicationIntent=ReadOnly).
      Inserts - new requisitions (+ lines, approvals), purchase orders, invoices, expense reports.
      Updates - requisition edits/approvals, goods receipt, invoice approval/payment/dispute resolution,
                expense approval/reimbursement.
      Deletes - withdrawn requisitions, recalled expense reports and a retention purge.

    Only rows created by the load generator are updated or deleted. They are identified by the
    prefixes LGR- (requisitions), LGP- (purchase orders), LGI- (invoices) and LGE- (expense reports),
    so the seed data from CoupaDemo.sql is never modified. Use -Cleanup to remove all load rows.

    Writes go through the AG listener with MultiSubnetFailover, and workers reconnect after errors,
    so the load keeps running through a manual or automatic failover.

.EXAMPLE
    .\scripts\sample-data\Start-CoupaDemoLoad.ps1                       # 8 workers until Ctrl+C

.EXAMPLE
    .\scripts\sample-data\Start-CoupaDemoLoad.ps1 -Workers 16 -ThinkTimeMs 0 -DurationMinutes 30

.EXAMPLE
    .\scripts\sample-data\Start-CoupaDemoLoad.ps1 -Cleanup              # remove all load-generated rows
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$ReadServer,
    [string]$SqlLogin,
    [string]$SqlPassword,
    [ValidateRange(1, 128)][int]$Workers = 8,
    [ValidateRange(0, 100000)][int]$DurationMinutes = 0,
    [ValidateRange(0, 60000)][int]$ThinkTimeMs = 200,
    [ValidateRange(0, 100)][int]$ReadPercent = 60,
    [ValidateRange(0, 100)][int]$ReadFromSecondaryPercent = 50,
    [ValidateRange(1, 100000)][int]$RetentionMinutes = 30,
    [ValidateRange(1, 3600)][int]$ReportIntervalSeconds = 10,
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

. (Join-Path $repoRoot 'scripts\arc\ArcEvalCommon.ps1')
$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot
if (-not $SqlLogin) { $SqlLogin = $azdEnv['AZURE_SQL_ADMIN_LOGIN'] }
if (-not $SqlPassword) { $SqlPassword = $azdEnv['AZURE_SQL_ADMIN_PASSWORD'] }
if (-not $Server) {
    $listenerIp = if ($azdEnv['AZURE_LISTENER_IP1']) { $azdEnv['AZURE_LISTENER_IP1'] } else { '10.0.10.11' }
    $Server = "$listenerIp,14333"
}
if (-not $ReadServer) {
    $sql2 = if ($azdEnv['AZURE_SQL2_PRIVATE_IP']) { $azdEnv['AZURE_SQL2_PRIVATE_IP'] } else { '10.0.11.4' }
    $ReadServer = "$sql2,1433"
}
if (-not $SqlLogin -or -not $SqlPassword) { throw 'Provide -SqlLogin/-SqlPassword or set AZURE_SQL_ADMIN_LOGIN/AZURE_SQL_ADMIN_PASSWORD in the azd environment.' }

function New-ConnectionString([string]$DataSource, [switch]$ReadOnly) {
    $quotedPassword = '"' + $SqlPassword.Replace('"', '""') + '"'
    $cs = "Server=$DataSource;User ID=$SqlLogin;Password=$quotedPassword;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;MultiSubnetFailover=True;Max Pool Size=200;Application Name=CoupaDemoLoadGenerator"
    if ($ReadOnly) { $cs += ';ApplicationIntent=ReadOnly' }
    $cs
}
$writeCs = New-ConnectionString $Server
$readCs = New-ConnectionString $ReadServer -ReadOnly

function Invoke-SqlScalar([string]$ConnectionString, [string]$Query, [int]$Timeout = 60) {
    $conn = New-Object System.Data.SqlClient.SqlConnection "$ConnectionString;Database=master"
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $Timeout
        $cmd.ExecuteScalar()
    }
    finally { $conn.Dispose() }
}

# ---------------------------------------------------------------------------------------------
# Workload definition
# ---------------------------------------------------------------------------------------------
function Get-PurgeSql([string]$CutoffExpression, [int]$BatchSize) {
    @"
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @cutoff datetime2(0) = $CutoffExpression;
DECLARE @req TABLE (RequisitionId int PRIMARY KEY);
DECLARE @inv TABLE (InvoiceId int PRIMARY KEY);

-- Invoices for purged purchase orders, plus any orphaned load-test invoices.
INSERT @inv (InvoiceId)
SELECT i.InvoiceId FROM CoupaInvoicing.dbo.Invoices i
WHERE i.InvoiceNumber LIKE 'LGI-%'
  AND (    EXISTS (SELECT 1 FROM CoupaProcurement.dbo.PurchaseOrders p
                   JOIN CoupaProcurement.dbo.Requisitions r ON r.RequisitionId = p.RequisitionId
                   WHERE p.PONumber = i.PONumber AND r.SubmittedAt < @cutoff)
       OR NOT EXISTS (SELECT 1 FROM CoupaProcurement.dbo.PurchaseOrders p WHERE p.PONumber = i.PONumber));
BEGIN TRANSACTION;
DELETE CoupaInvoicing.dbo.Payments     WHERE InvoiceId IN (SELECT InvoiceId FROM @inv);
DELETE CoupaInvoicing.dbo.InvoiceLines WHERE InvoiceId IN (SELECT InvoiceId FROM @inv);
DELETE CoupaInvoicing.dbo.Invoices     WHERE InvoiceId IN (SELECT InvoiceId FROM @inv);
COMMIT;

BEGIN TRANSACTION;
INSERT @req (RequisitionId)
SELECT TOP ($BatchSize) RequisitionId FROM CoupaProcurement.dbo.Requisitions WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE ReqNumber LIKE 'LGR-%' AND SubmittedAt < @cutoff ORDER BY RequisitionId;
DELETE pol FROM CoupaProcurement.dbo.PurchaseOrderLines pol
  JOIN CoupaProcurement.dbo.PurchaseOrders p ON p.PurchaseOrderId = pol.PurchaseOrderId
  JOIN @req r ON r.RequisitionId = p.RequisitionId;
DELETE p FROM CoupaProcurement.dbo.PurchaseOrders p JOIN @req r ON r.RequisitionId = p.RequisitionId;
DELETE a FROM CoupaProcurement.dbo.Approvals a JOIN @req r ON r.RequisitionId = a.RequisitionId;
DELETE l FROM CoupaProcurement.dbo.RequisitionLines l JOIN @req r ON r.RequisitionId = l.RequisitionId;
DELETE q FROM CoupaProcurement.dbo.Requisitions q JOIN @req r ON r.RequisitionId = q.RequisitionId;
COMMIT;

BEGIN TRANSACTION;
DELETE l FROM CoupaExpenses.dbo.ExpenseLines l
  JOIN CoupaExpenses.dbo.ExpenseReports er ON er.ExpenseReportId = l.ExpenseReportId
WHERE er.ReportNumber LIKE 'LGE-%' AND er.SubmittedAt < @cutoff;
DELETE CoupaExpenses.dbo.ExpenseReports WHERE ReportNumber LIKE 'LGE-%' AND SubmittedAt < @cutoff;
COMMIT;
"@
}

$ops = New-Object System.Collections.Generic.List[hashtable]
function Add-Op([string]$Name, [ValidateSet('Read', 'Insert', 'Update', 'Delete')][string]$Kind, [string]$Db, [int]$Weight, [string]$Sql) {
    $ops.Add(@{ Name = $Name; Kind = $Kind; Db = $Db; Weight = $Weight; Sql = "SET NOCOUNT ON; SET XACT_ABORT ON;`n$Sql" })
}

# ---- Reads -----------------------------------------------------------------------------------
Add-Op 'SupplierScorecard' Read CoupaProcurement 2 'SELECT TOP (10) * FROM dbo.vw_SupplierSpend ORDER BY TotalSpend DESC;'
Add-Op 'SpendByCommodity' Read CoupaProcurement 2 'SELECT * FROM dbo.vw_SpendByCommodity ORDER BY TotalSpend DESC;'
Add-Op 'BudgetVsSpend' Read CoupaProcurement 2 'SELECT * FROM dbo.vw_BudgetVsSpend ORDER BY PercentOfBudget DESC;'
Add-Op 'MonthlySpendTrend' Read CoupaProcurement 1 @'
SELECT m.SpendMonth, m.Spend,
       SUM(m.Spend) OVER (ORDER BY m.SpendMonth ROWS UNBOUNDED PRECEDING) AS CumulativeSpend,
       m.Spend - LAG(m.Spend) OVER (ORDER BY m.SpendMonth) AS ChangeVsPriorMonth
FROM (SELECT DATEFROMPARTS(YEAR(po.OrderDate), MONTH(po.OrderDate), 1) AS SpendMonth, SUM(pol.LineTotal) AS Spend
      FROM dbo.PurchaseOrders po JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.PurchaseOrderId
      GROUP BY DATEFROMPARTS(YEAR(po.OrderDate), MONTH(po.OrderDate), 1)) m
ORDER BY m.SpendMonth;
'@
Add-Op 'CatalogSearch' Read CoupaProcurement 4 @'
DECLARE @kw nvarchar(40) = (SELECT TOP (1) LEFT(ItemName, CHARINDEX(N' ', ItemName + N' ') - 1) FROM dbo.CatalogItems ORDER BY NEWID());
SELECT ci.ItemId, ci.ItemName, ci.UnitOfMeasure, ci.UnitPrice, s.SupplierName, c.Name AS Commodity
FROM dbo.CatalogItems ci
JOIN dbo.Suppliers s ON s.SupplierId = ci.SupplierId
JOIN dbo.Commodities c ON c.CommodityId = ci.CommodityId
WHERE ci.ItemName LIKE N'%' + @kw + N'%'
ORDER BY ci.UnitPrice;
'@
Add-Op 'MyRequisitions' Read CoupaProcurement 4 @'
DECLARE @emp int = (SELECT TOP (1) EmployeeId FROM dbo.Employees ORDER BY NEWID());
SELECT TOP (25) rq.ReqNumber, rq.Status, rq.SubmittedAt, rq.NeedByDate, cc.Name AS CostCenter,
       COUNT(*) AS Lines, SUM(rl.LineTotal) AS Total
FROM dbo.Requisitions rq
JOIN dbo.CostCenters cc ON cc.CostCenterId = rq.CostCenterId
JOIN dbo.RequisitionLines rl ON rl.RequisitionId = rq.RequisitionId
WHERE rq.RequesterId = @emp
GROUP BY rq.ReqNumber, rq.Status, rq.SubmittedAt, rq.NeedByDate, cc.Name
ORDER BY rq.SubmittedAt DESC;
'@
Add-Op 'PurchaseOrderDetail' Read CoupaProcurement 4 @'
DECLARE @po int = (SELECT TOP (1) PurchaseOrderId FROM dbo.PurchaseOrders ORDER BY NEWID());
SELECT po.PONumber, po.Status, po.OrderDate, po.ShipToSite, s.SupplierName, pol.LineNumber, ci.ItemName,
       pol.Quantity, pol.QuantityReceived, pol.UnitPrice, pol.LineTotal
FROM dbo.PurchaseOrders po
JOIN dbo.Suppliers s ON s.SupplierId = po.SupplierId
JOIN dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = po.PurchaseOrderId
JOIN dbo.CatalogItems ci ON ci.ItemId = pol.ItemId
WHERE po.PurchaseOrderId = @po
ORDER BY pol.LineNumber;
'@
Add-Op 'ApprovalQueue' Read CoupaProcurement 3 @'
DECLARE @approver int = (SELECT TOP (1) ApproverId FROM dbo.Approvals ORDER BY NEWID());
SELECT a.ApprovalStep, rq.ReqNumber, e.FullName AS Requester, rq.SubmittedAt, SUM(rl.LineTotal) AS Total
FROM dbo.Approvals a
JOIN dbo.Requisitions rq ON rq.RequisitionId = a.RequisitionId
JOIN dbo.Employees e ON e.EmployeeId = rq.RequesterId
JOIN dbo.RequisitionLines rl ON rl.RequisitionId = rq.RequisitionId
WHERE a.ApproverId = @approver AND a.Decision = 'Pending'
GROUP BY a.ApprovalStep, rq.ReqNumber, e.FullName, rq.SubmittedAt
ORDER BY rq.SubmittedAt;
'@
Add-Op 'InvoiceAging' Read CoupaInvoicing 2 @'
SELECT Status, AgingBucket, COUNT(*) AS Invoices, SUM(TotalAmount) AS Amount
FROM dbo.vw_InvoiceAging GROUP BY Status, AgingBucket ORDER BY Status, AgingBucket;
'@
Add-Op 'SupplierStatement' Read CoupaInvoicing 3 @'
DECLARE @sid int = (SELECT TOP (1) SupplierId FROM dbo.Invoices ORDER BY NEWID());
SELECT s.SupplierName, i.InvoiceNumber, i.PONumber, i.InvoiceDate, i.DueDate, i.TotalAmount, i.Status,
       p.PaymentDate, p.Amount AS PaidAmount, p.PaymentMethod, p.EarlyPayDiscount
FROM dbo.Invoices i
LEFT JOIN dbo.Payments p ON p.InvoiceId = i.InvoiceId
JOIN CoupaProcurement.dbo.Suppliers s ON s.SupplierId = i.SupplierId
WHERE i.SupplierId = @sid
ORDER BY i.InvoiceDate DESC;
'@
Add-Op 'DuplicateInvoiceCheck' Read CoupaInvoicing 1 @'
SELECT SupplierId, Subtotal, COUNT(*) AS Invoices, MIN(InvoiceNumber) AS FirstInvoice, MAX(InvoiceNumber) AS LastInvoice
FROM dbo.Invoices GROUP BY SupplierId, Subtotal HAVING COUNT(*) > 1;
'@
Add-Op 'MyExpenseReports' Read CoupaExpenses 3 @'
DECLARE @email varchar(120) = (SELECT TOP (1) EmployeeEmail FROM dbo.ExpenseReports ORDER BY NEWID());
SELECT * FROM dbo.vw_ExpenseSummary WHERE EmployeeEmail = @email ORDER BY ReportNumber DESC;
'@
Add-Op 'OutOfPolicySpend' Read CoupaExpenses 1 @'
SELECT c.Name AS Category, COUNT(*) AS Lines, SUM(l.Amount) AS Amount,
       SUM(CASE WHEN l.OutOfPolicy = 1 THEN l.Amount ELSE 0 END) AS OutOfPolicyAmount
FROM dbo.ExpenseLines l JOIN dbo.ExpenseCategories c ON c.CategoryId = l.CategoryId
GROUP BY c.Name ORDER BY OutOfPolicyAmount DESC;
'@

# ---- Writes (only rows with the LG* prefixes are ever updated or deleted) ----------------------
Add-Op 'CreateRequisition' Insert CoupaProcurement 6 @'
DECLARE @emp int, @cc int, @mgr int, @reqId int, @r int = ABS(CHECKSUM(NEWID())), @lines int;
DECLARE @inserted TABLE (LineTotal decimal(14,2));
SET @lines = 1 + @r % 4;
SELECT TOP (1) @emp = EmployeeId, @cc = CostCenterId, @mgr = COALESCE(ManagerId, 2) FROM dbo.Employees ORDER BY NEWID();
BEGIN TRANSACTION;
INSERT dbo.Requisitions (ReqNumber, RequesterId, CostCenterId, Status, SubmittedAt, NeedByDate, Justification)
VALUES (CONCAT('LGR-', LEFT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 12)), @emp, @cc, 'Pending Approval', SYSDATETIME(),
        DATEADD(day, 7 + @r % 30, CAST(GETDATE() AS date)),
        CHOOSE(1 + @r % 6, N'New hire onboarding equipment', N'Quarterly replenishment', N'Customer event support',
               N'Project Phoenix rollout', N'Lab expansion', N'Replacement for end-of-life assets'));
SET @reqId = SCOPE_IDENTITY();
INSERT dbo.RequisitionLines (RequisitionId, LineNumber, ItemId, Quantity, UnitPrice)
OUTPUT inserted.LineTotal INTO @inserted
SELECT @reqId, ROW_NUMBER() OVER (ORDER BY ci.ItemId), ci.ItemId,
       CASE WHEN ci.UnitPrice >= 10000 THEN 1
            WHEN ci.UnitPrice >= 1000 THEN 1 + ABS(CHECKSUM(NEWID())) % 5
            ELSE 1 + ABS(CHECKSUM(NEWID())) % 40 END,
       ci.UnitPrice
FROM (SELECT TOP (@lines) ItemId, UnitPrice FROM dbo.CatalogItems ORDER BY NEWID()) ci;
INSERT dbo.Approvals (RequisitionId, ApproverId, ApprovalStep, Decision) VALUES (@reqId, @mgr, 1, 'Pending');
IF (SELECT SUM(LineTotal) FROM @inserted) > 25000
    INSERT dbo.Approvals (RequisitionId, ApproverId, ApprovalStep, Decision) VALUES (@reqId, 2, 2, 'Pending');
COMMIT;
'@
Add-Op 'EditRequisition' Update CoupaProcurement 2 @'
DECLARE @candidate int, @reqId int;
SELECT TOP (1) @candidate = RequisitionId FROM dbo.Requisitions
WHERE Status = 'Pending Approval' AND ReqNumber LIKE 'LGR-%' ORDER BY NEWID();
BEGIN TRANSACTION;
SET @reqId = (SELECT RequisitionId FROM dbo.Requisitions WITH (UPDLOCK, READPAST, ROWLOCK)
              WHERE RequisitionId = @candidate AND Status = 'Pending Approval');
IF @reqId IS NOT NULL
BEGIN
    UPDATE TOP (1) dbo.RequisitionLines SET Quantity = Quantity + 1 WHERE RequisitionId = @reqId;
    UPDATE dbo.Requisitions SET NeedByDate = DATEADD(day, 7, NeedByDate),
           Justification = N'Updated by requester: quantity change'
    WHERE RequisitionId = @reqId;
END
COMMIT;
'@
Add-Op 'ApproveRequisition' Update CoupaProcurement 5 @'
DECLARE @reqId int, @reject bit = CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN 1 ELSE 0 END;
BEGIN TRANSACTION;
SELECT TOP (1) @reqId = RequisitionId FROM dbo.Requisitions WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE Status = 'Pending Approval' AND ReqNumber LIKE 'LGR-%' ORDER BY RequisitionId;
IF @reqId IS NOT NULL
BEGIN
    UPDATE dbo.Approvals
    SET Decision = CASE @reject WHEN 1 THEN 'Rejected' ELSE 'Approved' END, DecidedAt = SYSDATETIME(),
        Comments = CASE @reject WHEN 1 THEN N'Please source from a preferred contract supplier' END
    WHERE RequisitionId = @reqId AND Decision = 'Pending';
    UPDATE dbo.Requisitions SET Status = CASE @reject WHEN 1 THEN 'Rejected' ELSE 'Approved' END WHERE RequisitionId = @reqId;
END
COMMIT;
'@
Add-Op 'IssuePurchaseOrder' Insert CoupaProcurement 4 @'
DECLARE @reqId int, @r int = ABS(CHECKSUM(NEWID()));
DECLARE @po TABLE (PurchaseOrderId int, SupplierId int);
BEGIN TRANSACTION;
SELECT TOP (1) @reqId = RequisitionId FROM dbo.Requisitions WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE Status = 'Approved' AND ReqNumber LIKE 'LGR-%' ORDER BY RequisitionId;
IF @reqId IS NOT NULL
BEGIN
    INSERT dbo.PurchaseOrders (PONumber, RequisitionId, SupplierId, Status, OrderDate, Currency, ShipToSite)
    OUTPUT inserted.PurchaseOrderId, inserted.SupplierId INTO @po
    SELECT CONCAT('LGP-', LEFT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 12)), @reqId, s.SupplierId, 'Issued',
           CAST(GETDATE() AS date), 'USD',
           CHOOSE(1 + @r % 4, N'Seattle HQ', N'Austin Campus', N'London Office', N'Singapore Hub')
    FROM (SELECT DISTINCT ci.SupplierId FROM dbo.RequisitionLines rl
          JOIN dbo.CatalogItems ci ON ci.ItemId = rl.ItemId WHERE rl.RequisitionId = @reqId) s;
    INSERT dbo.PurchaseOrderLines (PurchaseOrderId, LineNumber, ItemId, Quantity, QuantityReceived, UnitPrice)
    SELECT p.PurchaseOrderId, ROW_NUMBER() OVER (PARTITION BY p.PurchaseOrderId ORDER BY rl.LineNumber),
           rl.ItemId, rl.Quantity, 0, rl.UnitPrice
    FROM @po p
    JOIN dbo.RequisitionLines rl ON rl.RequisitionId = @reqId
    JOIN dbo.CatalogItems ci ON ci.ItemId = rl.ItemId AND ci.SupplierId = p.SupplierId;
    UPDATE dbo.Requisitions SET Status = 'Ordered' WHERE RequisitionId = @reqId;
END
COMMIT;
'@
Add-Op 'ReceiveGoods' Update CoupaProcurement 4 @'
DECLARE @poId int;
BEGIN TRANSACTION;
SELECT TOP (1) @poId = PurchaseOrderId FROM dbo.PurchaseOrders WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE Status = 'Issued' AND PONumber LIKE 'LGP-%' ORDER BY PurchaseOrderId;
IF @poId IS NOT NULL
BEGIN
    UPDATE dbo.PurchaseOrderLines SET QuantityReceived = Quantity WHERE PurchaseOrderId = @poId;
    UPDATE dbo.PurchaseOrders SET Status = 'Received' WHERE PurchaseOrderId = @poId;
END
COMMIT;
'@
Add-Op 'CreateInvoice' Insert CoupaInvoicing 4 @'
DECLARE @po varchar(20), @sid int, @snum varchar(12), @terms int, @invId int, @rc int,
        @variance bit = CASE WHEN ABS(CHECKSUM(NEWID())) % 12 = 0 THEN 1 ELSE 0 END;
BEGIN TRANSACTION;
-- Serialize PO selection so two workers never invoice the same PO.
EXEC @rc = sp_getapplock @Resource = 'CoupaLoad-CreateInvoice', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
IF @rc < 0 BEGIN ROLLBACK; RETURN; END
SELECT TOP (1) @po = p.PONumber, @sid = p.SupplierId, @snum = s.SupplierNumber,
       @terms = CAST(REPLACE(s.PaymentTerms, 'Net ', '') AS int)
FROM CoupaProcurement.dbo.PurchaseOrders p
JOIN CoupaProcurement.dbo.Suppliers s ON s.SupplierId = p.SupplierId
WHERE p.Status = 'Received' AND p.PONumber LIKE 'LGP-%'
  AND NOT EXISTS (SELECT 1 FROM dbo.Invoices i WHERE i.PONumber = p.PONumber)
ORDER BY p.PurchaseOrderId;
IF @po IS NOT NULL
BEGIN
    INSERT dbo.Invoices (InvoiceNumber, SupplierId, SupplierNumber, PONumber, InvoiceDate, DueDate, Subtotal, TaxAmount, Currency, MatchStatus, Status)
    SELECT CONCAT('LGI-', SUBSTRING(@po, 5, 16)), @sid, @snum, @po, CAST(GETDATE() AS date),
           DATEADD(day, @terms, CAST(GETDATE() AS date)),
           CAST(SUM(pol.QuantityReceived * pol.UnitPrice) * CASE @variance WHEN 1 THEN 1.06 ELSE 1 END AS decimal(14,2)),
           CAST(SUM(pol.QuantityReceived * pol.UnitPrice) * 0.0825 AS decimal(14,2)), 'USD',
           CASE @variance WHEN 1 THEN 'Price Variance' ELSE '3-Way Matched' END,
           CASE @variance WHEN 1 THEN 'Disputed' ELSE 'Pending Approval' END
    FROM CoupaProcurement.dbo.PurchaseOrders p
    JOIN CoupaProcurement.dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = p.PurchaseOrderId
    WHERE p.PONumber = @po;
    SET @invId = SCOPE_IDENTITY();
    INSERT dbo.InvoiceLines (InvoiceId, LineNumber, Description, Quantity, UnitPrice)
    SELECT @invId, pol.LineNumber, ci.ItemName, pol.QuantityReceived,
           CAST(pol.UnitPrice * CASE @variance WHEN 1 THEN 1.06 ELSE 1 END AS decimal(12,2))
    FROM CoupaProcurement.dbo.PurchaseOrders p
    JOIN CoupaProcurement.dbo.PurchaseOrderLines pol ON pol.PurchaseOrderId = p.PurchaseOrderId
    JOIN CoupaProcurement.dbo.CatalogItems ci ON ci.ItemId = pol.ItemId
    WHERE p.PONumber = @po;
END
COMMIT;
'@
Add-Op 'ProcessInvoice' Update CoupaInvoicing 5 @'
DECLARE @invId int, @status varchar(20), @r int = ABS(CHECKSUM(NEWID()));
BEGIN TRANSACTION;
SELECT TOP (1) @invId = InvoiceId, @status = Status FROM dbo.Invoices WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE Status IN ('Pending Approval', 'Approved', 'Disputed') AND InvoiceNumber LIKE 'LGI-%' ORDER BY InvoiceId;
IF @status = 'Pending Approval'
    UPDATE dbo.Invoices SET Status = 'Approved' WHERE InvoiceId = @invId;
ELSE IF @status = 'Disputed'
BEGIN
    -- Supplier issued a credit memo: bring the invoice back to the PO price.
    UPDATE dbo.InvoiceLines SET UnitPrice = CAST(UnitPrice / 1.06 AS decimal(12,2)) WHERE InvoiceId = @invId;
    UPDATE dbo.Invoices SET Subtotal = CAST(Subtotal / 1.06 AS decimal(14,2)), MatchStatus = '3-Way Matched', Status = 'Approved'
    WHERE InvoiceId = @invId;
END
ELSE IF @status = 'Approved'
BEGIN
    UPDATE dbo.Invoices SET Status = 'Paid' WHERE InvoiceId = @invId;
    INSERT dbo.Payments (InvoiceId, PaymentDate, Amount, PaymentMethod, BankReference, EarlyPayDiscount)
    SELECT InvoiceId, CAST(GETDATE() AS date),
           CASE WHEN @r % 5 = 0 THEN CAST(TotalAmount * 0.98 AS decimal(14,2)) ELSE TotalAmount END,
           CHOOSE(1 + @r % 4, 'ACH', 'Virtual Card', 'Wire', 'Check'),
           CONCAT('LGPMT', InvoiceId),
           CASE WHEN @r % 5 = 0 THEN CAST(TotalAmount * 0.02 AS decimal(12,2)) ELSE 0 END
    FROM dbo.Invoices WHERE InvoiceId = @invId;
END
COMMIT;
'@
Add-Op 'SubmitExpenseReport' Insert CoupaExpenses 4 @'
DECLARE @emp int, @email varchar(120), @r int = ABS(CHECKSUM(NEWID())), @rid int, @lines int;
DECLARE @l TABLE (CategoryId int, PolicyLimit decimal(10,2), ReceiptRequiredOver decimal(10,2), h int);
SET @lines = 2 + @r % 4;
SELECT TOP (1) @emp = EmployeeId, @email = Email FROM CoupaProcurement.dbo.Employees ORDER BY NEWID();
INSERT @l SELECT TOP (@lines) CategoryId, PolicyLimit, ReceiptRequiredOver, ABS(CHECKSUM(NEWID()))
FROM dbo.ExpenseCategories ORDER BY NEWID();
BEGIN TRANSACTION;
INSERT dbo.ExpenseReports (ReportNumber, EmployeeId, EmployeeEmail, Title, Status, SubmittedAt, ReimbursedAt)
VALUES (CONCAT('LGE-', LEFT(REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), 12)), @emp, @email,
        CHOOSE(1 + @r % 6, N'Customer visit - Chicago', N'Team offsite - Denver', N'Sales kickoff - Las Vegas',
               N'Supplier audit - Singapore', N'Training - Boston', N'Client dinner - New York'),
        'Submitted', SYSDATETIME(), NULL);
SET @rid = SCOPE_IDENTITY();
INSERT dbo.ExpenseLines (ExpenseReportId, CategoryId, ExpenseDate, Merchant, City, Amount, Currency, ReceiptAttached, OutOfPolicy)
SELECT @rid, l.CategoryId, DATEADD(day, -(l.h % 14), CAST(GETDATE() AS date)),
       CHOOSE(1 + l.h % 6, N'Fourth Coffee', N'Contoso Air', N'Margie''s Travel Hotels', N'Contoso Rideshare',
              N'Wingtip Steakhouse', N'Southridge Wireless'),
       CHOOSE(1 + @r % 6, N'Chicago', N'Denver', N'Las Vegas', N'Singapore', N'Boston', N'New York'),
       a.Amount, 'USD',
       CASE WHEN a.Amount > l.ReceiptRequiredOver OR l.h % 3 <> 0 THEN 1 ELSE 0 END,
       CASE WHEN a.Amount > l.PolicyLimit THEN 1 ELSE 0 END
FROM @l l
CROSS APPLY (SELECT CAST(l.PolicyLimit * (20 + l.h % 100) / 100.0 AS decimal(10,2)) AS Amount) a;
COMMIT;
'@
Add-Op 'ProcessExpenseReport' Update CoupaExpenses 4 @'
DECLARE @rid int, @status varchar(20), @reject bit = CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN 1 ELSE 0 END;
BEGIN TRANSACTION;
SELECT TOP (1) @rid = ExpenseReportId, @status = Status FROM dbo.ExpenseReports WITH (UPDLOCK, READPAST, ROWLOCK)
WHERE Status IN ('Submitted', 'Approved') AND ReportNumber LIKE 'LGE-%' ORDER BY ExpenseReportId;
IF @status = 'Submitted'
    UPDATE dbo.ExpenseReports SET Status = CASE @reject WHEN 1 THEN 'Rejected' ELSE 'Approved' END WHERE ExpenseReportId = @rid;
ELSE IF @status = 'Approved'
    UPDATE dbo.ExpenseReports SET Status = 'Reimbursed', ReimbursedAt = SYSDATETIME() WHERE ExpenseReportId = @rid;
COMMIT;
'@
Add-Op 'WithdrawRequisition' Delete CoupaProcurement 1 @'
DECLARE @candidate int, @reqId int;
SELECT TOP (1) @candidate = RequisitionId FROM dbo.Requisitions
WHERE Status = 'Pending Approval' AND ReqNumber LIKE 'LGR-%' ORDER BY NEWID();
BEGIN TRANSACTION;
SET @reqId = (SELECT RequisitionId FROM dbo.Requisitions WITH (UPDLOCK, READPAST, ROWLOCK)
              WHERE RequisitionId = @candidate AND Status = 'Pending Approval');
IF @reqId IS NOT NULL
BEGIN
    DELETE dbo.Approvals WHERE RequisitionId = @reqId;
    DELETE dbo.RequisitionLines WHERE RequisitionId = @reqId;
    DELETE dbo.Requisitions WHERE RequisitionId = @reqId;
END
COMMIT;
'@
Add-Op 'RecallExpenseReport' Delete CoupaExpenses 1 @'
DECLARE @candidate int, @rid int;
SELECT TOP (1) @candidate = ExpenseReportId FROM dbo.ExpenseReports
WHERE Status = 'Submitted' AND ReportNumber LIKE 'LGE-%' ORDER BY NEWID();
BEGIN TRANSACTION;
SET @rid = (SELECT ExpenseReportId FROM dbo.ExpenseReports WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE ExpenseReportId = @candidate AND Status = 'Submitted');
IF @rid IS NOT NULL
BEGIN
    DELETE dbo.ExpenseLines WHERE ExpenseReportId = @rid;
    DELETE dbo.ExpenseReports WHERE ExpenseReportId = @rid;
END
COMMIT;
'@
Add-Op 'PurgeLoadData' Delete CoupaProcurement 1 (Get-PurgeSql "DATEADD(minute, -$RetentionMinutes, SYSDATETIME())" 200)

$loadRowCountSql = @"
SELECT (SELECT COUNT(*) FROM CoupaProcurement.dbo.Requisitions WHERE ReqNumber LIKE 'LGR-%')
     + (SELECT COUNT(*) FROM CoupaInvoicing.dbo.Invoices WHERE InvoiceNumber LIKE 'LGI-%')
     + (SELECT COUNT(*) FROM CoupaExpenses.dbo.ExpenseReports WHERE ReportNumber LIKE 'LGE-%')
"@

# ---------------------------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------------------------
Write-Host "`n==> Connecting to $Server as $SqlLogin" -ForegroundColor Cyan
$primary = Invoke-SqlScalar $writeCs 'SELECT @@SERVERNAME'
$missing = Invoke-SqlScalar $writeCs "SELECT COUNT(*) FROM (VALUES (N'CoupaProcurement'), (N'CoupaInvoicing'), (N'CoupaExpenses')) d(n) WHERE DB_ID(d.n) IS NULL"
if ($missing -gt 0) { throw 'Coupa demo databases not found. Run .\scripts\sample-data\New-CoupaDemoDatabases.ps1 first.' }
if (-not (Invoke-SqlScalar $writeCs "SELECT CASE WHEN EXISTS (SELECT 1 FROM CoupaProcurement.sys.indexes WHERE name = N'IX_Approvals_Requisition') AND NOT EXISTS (SELECT 1 FROM sys.databases WHERE name LIKE N'Coupa%' AND is_read_committed_snapshot_on = 0) THEN 1 ELSE 0 END")) {
    Write-Warning 'Foreign-key indexes or READ_COMMITTED_SNAPSHOT are missing, which causes blocking and deadlocks under load. Rerun .\scripts\sample-data\New-CoupaDemoDatabases.ps1 (idempotent) to add them.'
}
Write-Host "  Connected to $primary" -ForegroundColor Green

if ($Cleanup) {
    Write-Host "`n==> Removing load-generated rows (LGR-/LGP-/LGI-/LGE-)" -ForegroundColor Cyan
    $before = Invoke-SqlScalar $writeCs $loadRowCountSql
    $purgeAll = Get-PurgeSql 'DATEADD(day, 1, SYSDATETIME())' 5000
    for ($i = 0; $i -lt 100; $i++) {
        $conn = New-Object System.Data.SqlClient.SqlConnection "$writeCs;Database=CoupaProcurement"
        try {
            $conn.Open(); $cmd = $conn.CreateCommand(); $cmd.CommandText = $purgeAll; $cmd.CommandTimeout = 600
            [void]$cmd.ExecuteNonQuery()
        }
        finally { $conn.Dispose() }
        $remaining = Invoke-SqlScalar $writeCs $loadRowCountSql
        if ($remaining -eq 0) { break }
    }
    Write-Host "  Removed $before load-generated requisitions, invoices and expense reports ($remaining remaining)" -ForegroundColor Green
    return
}

$readOps = @(); $writeOps = @()
for ($i = 0; $i -lt $ops.Count; $i++) { if ($ops[$i].Kind -eq 'Read') { $readOps += $i } else { $writeOps += $i } }
function Get-Cumulative([int[]]$Indexes) {
    $sum = 0; , @($Indexes | ForEach-Object { $sum += $ops[$_].Weight; $sum })
}
$readCum = Get-Cumulative $readOps
$writeCum = Get-Cumulative $writeOps

# Each worker owns its own counter arrays, so no locking is needed; the main thread only reads them.
$state = [hashtable]::Synchronized(@{
        Stop      = $false
        LastError = $null
        Success   = New-Object 'long[][]' $Workers
        Failures  = New-Object 'long[][]' $Workers
        Millis    = New-Object 'long[][]' $Workers
        Secondary = New-Object 'long[]' $Workers
        Deadlocks = New-Object 'long[]' $Workers
    })
for ($w = 0; $w -lt $Workers; $w++) {
    $state.Success[$w] = New-Object 'long[]' $ops.Count
    $state.Failures[$w] = New-Object 'long[]' $ops.Count
    $state.Millis[$w] = New-Object 'long[]' $ops.Count
}

$worker = {
    param($State, $Ops, $ReadOps, $WriteOps, $ReadCum, $WriteCum, $WriteCs, $ReadCs,
        $ReadPercent, $SecondaryPercent, $ThinkTimeMs, $Id)
    $rand = [System.Random]::new([Environment]::TickCount -bxor ($Id * 7919))
    $ok = $State.Success[$Id]; $fail = $State.Failures[$Id]; $ms = $State.Millis[$Id]
    while (-not $State.Stop) {
        if ($ReadOps.Count -gt 0 -and ($WriteOps.Count -eq 0 -or $rand.Next(100) -lt $ReadPercent)) { $set = $ReadOps; $cum = $ReadCum }
        else { $set = $WriteOps; $cum = $WriteCum }
        $pick = $rand.Next($cum[-1]); $k = 0
        while ($pick -ge $cum[$k]) { $k++ }
        $i = $set[$k]; $op = $Ops[$i]

        $toSecondary = $op.Kind -eq 'Read' -and $rand.Next(100) -lt $SecondaryPercent
        $cs = if ($toSecondary) { $ReadCs } else { $WriteCs }
        $conn = New-Object System.Data.SqlClient.SqlConnection "$cs;Database=$($op.Db)"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $op.Sql
            $cmd.CommandTimeout = 60
            for ($attempt = 1; ; $attempt++) {
                $reader = $null
                try {
                    if ($op.Kind -eq 'Read') {
                        $reader = $cmd.ExecuteReader()
                        do { while ($reader.Read()) { } } while ($reader.NextResult())
                        $reader.Close()
                        if ($toSecondary) { $State.Secondary[$Id]++ }
                    }
                    else { [void]$cmd.ExecuteNonQuery() }
                    break
                }
                catch {
                    # Retry deadlock victims like a real application would.
                    $sqlEx = $_.Exception.GetBaseException()
                    if ($reader -and -not $reader.IsClosed) { $reader.Close() }
                    if (-not ($sqlEx -is [System.Data.SqlClient.SqlException] -and $sqlEx.Number -eq 1205) -or $attempt -ge 3) { throw }
                    $State.Deadlocks[$Id]++
                    Start-Sleep -Milliseconds (20 + $rand.Next(100))
                }
            }
            $ok[$i]++
            $ms[$i] += $sw.ElapsedMilliseconds
        }
        catch {
            $fail[$i]++
            $msg = ($_.Exception.GetBaseException().Message -split "`r?`n")[0]
            $State.LastError = '{0:HH:mm:ss} {1} -> {2}: {3}' -f (Get-Date), $op.Name, $(if ($toSecondary) { 'secondary' } else { 'listener' }), $msg
            # Drop pooled connections that may point at the old primary, then back off briefly.
            try { [System.Data.SqlClient.SqlConnection]::ClearPool($conn) } catch { }
            Start-Sleep -Milliseconds (500 + $rand.Next(1500))
        }
        finally { $conn.Dispose() }
        if ($ThinkTimeMs -gt 0) { Start-Sleep -Milliseconds $rand.Next($ThinkTimeMs * 2 + 1) }
    }
}

function Get-Totals {
    $t = @{ Success = New-Object 'long[]' $ops.Count; Failures = New-Object 'long[]' $ops.Count; Millis = New-Object 'long[]' $ops.Count; Secondary = [long]0; Deadlocks = [long]0 }
    for ($w = 0; $w -lt $Workers; $w++) {
        for ($i = 0; $i -lt $ops.Count; $i++) {
            $t.Success[$i] += $state.Success[$w][$i]
            $t.Failures[$i] += $state.Failures[$w][$i]
            $t.Millis[$i] += $state.Millis[$w][$i]
        }
        $t.Secondary += $state.Secondary[$w]
        $t.Deadlocks += $state.Deadlocks[$w]
    }
    $t
}

# ---------------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------------
Write-Host "`n==> Starting load: $Workers workers, $ReadPercent% reads ($ReadFromSecondaryPercent% of reads on $ReadServer), think time 0-$(2 * $ThinkTimeMs) ms" -ForegroundColor Cyan
Write-Host "    Writes -> $Server | retention $RetentionMinutes min | $(if ($DurationMinutes) { "$DurationMinutes min" } else { 'Ctrl+C to stop' })" -ForegroundColor Gray
Write-Host ('    {0,-10} {1,8} {2,7} {3,7} {4,7} {5,7} {6,7} {7,7}  {8}' -f 'elapsed', 'ops/s', 'read/s', 'ins/s', 'upd/s', 'del/s', 'errors', 'avg ms', 'primary') -ForegroundColor Gray

$pool = [runspacefactory]::CreateRunspacePool(1, $Workers)
$pool.Open()
$jobs = @()
$clock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    for ($w = 0; $w -lt $Workers; $w++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).AddParameters(@{
                State = $state; Ops = $ops.ToArray(); ReadOps = $readOps; WriteOps = $writeOps; ReadCum = $readCum; WriteCum = $writeCum
                WriteCs = $writeCs; ReadCs = $readCs; ReadPercent = $ReadPercent; SecondaryPercent = $ReadFromSecondaryPercent
                ThinkTimeMs = $ThinkTimeMs; Id = $w
            })
        $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $prev = Get-Totals; $prevTime = 0.0; $lastError = $null
    while ($true) {
        Start-Sleep -Seconds $ReportIntervalSeconds
        $crashed = $jobs | Where-Object { $_.Handle.IsCompleted }
        if ($crashed) { throw "Worker stopped unexpectedly: $($crashed[0].PS.Streams.Error | Select-Object -First 1)" }

        $now = Get-Totals; $elapsed = $clock.Elapsed.TotalSeconds; $span = [math]::Max($elapsed - $prevTime, 0.001)
        $kind = @{ Read = 0; Insert = 0; Update = 0; Delete = 0 }; $errors = 0; $count = 0; $millis = 0
        for ($i = 0; $i -lt $ops.Count; $i++) {
            $d = $now.Success[$i] - $prev.Success[$i]
            $kind[$ops[$i].Kind] += $d; $count += $d
            $millis += $now.Millis[$i] - $prev.Millis[$i]
            $errors += $now.Failures[$i] - $prev.Failures[$i]
        }
        $primaryNow = try { Invoke-SqlScalar "$writeCs;Connect Timeout=5" 'SELECT @@SERVERNAME' 5 } catch { 'unavailable' }
        $line = '    {0,-10} {1,8:N1} {2,7:N1} {3,7:N1} {4,7:N1} {5,7:N1} {6,7} {7,7:N0}  {8}' -f `
        ([timespan]::FromSeconds([math]::Round($elapsed))).ToString(), ($count / $span), ($kind.Read / $span), ($kind.Insert / $span),
        ($kind.Update / $span), ($kind.Delete / $span), $errors, $(if ($count) { $millis / $count } else { 0 }), $primaryNow
        Write-Host $line -ForegroundColor $(if ($errors) { 'Yellow' } else { 'White' })
        if ($state.LastError -and $state.LastError -ne $lastError) {
            $lastError = $state.LastError
            Write-Host "      last error: $lastError" -ForegroundColor DarkYellow
        }
        $prev = $now; $prevTime = $elapsed
        if ($DurationMinutes -gt 0 -and $clock.Elapsed.TotalMinutes -ge $DurationMinutes) { break }
    }
}
finally {
    $state.Stop = $true
    $deadline = (Get-Date).AddSeconds(30)
    while (($jobs | Where-Object { -not $_.Handle.IsCompleted }) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    foreach ($j in $jobs) { if (-not $j.Handle.IsCompleted) { $j.PS.Stop() }; $j.PS.Dispose() }
    $pool.Close(); $pool.Dispose()

    $final = Get-Totals
    $elapsed = [math]::Max($clock.Elapsed.TotalSeconds, 0.001)
    Write-Host "`n==> Summary ($([timespan]::FromSeconds([math]::Round($elapsed)))): $(($final.Success | Measure-Object -Sum).Sum) operations, $(($final.Failures | Measure-Object -Sum).Sum) errors, $($final.Deadlocks) deadlocks retried, $($final.Secondary) reads served by the secondary" -ForegroundColor Cyan
    $summary = for ($i = 0; $i -lt $ops.Count; $i++) {
        [pscustomobject]@{
            Operation = $ops[$i].Name; Kind = $ops[$i].Kind; Database = $ops[$i].Db
            Succeeded = $final.Success[$i]; Failed = $final.Failures[$i]
            AvgMs = if ($final.Success[$i]) { [math]::Round($final.Millis[$i] / $final.Success[$i], 1) } else { 0 }
        }
    }
    $summary | Format-Table -AutoSize | Out-String | Write-Host
    try { Write-Host "  Load-generated rows currently in the databases: $(Invoke-SqlScalar $writeCs $loadRowCountSql) (remove with -Cleanup)" -ForegroundColor Gray } catch { }
}
