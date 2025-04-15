/* ==========================================================================================
   Client Risk Segmentation & Collections Strategy
   - Dataset: Home Credit Default Risk 
   - Tools: SAS 
   - Goal: Predict default risk and recommend collection strategies
   ==========================================================================================
*/


/* ----------------------------------------------
   STEP 1: Import Cleaned Training & Test Datasets
---------------------------------------------- */
proc import datafile="/home/u64131160/home_credit_default_risk/application_train_trimmed.csv"
	out=app_train dbms=csv replace;
	getnames=yes;
run;

proc import datafile="/home/u64131160/home_credit_default_risk/application_test_trimmed.csv"
	out=app_test dbms=csv replace;
	getnames=yes;
run;


/* -------------------------------------------------
   STEP 2: Feature Engineering on Training Dataset
------------------------------------------------- */
data app_train_clean;
	set app_train;

	/* Derived Features */
	AGE_YEARS = -DAYS_BIRTH / 365;
	EMPLOYED_YEARS = ifn(DAYS_EMPLOYED in (365243, .), ., -DAYS_EMPLOYED / 365);
	CREDIT_INCOME_RATIO = AMT_CREDIT / AMT_INCOME_TOTAL;
	ANNUITY_INCOME_RATIO = AMT_ANNUITY / AMT_INCOME_TOTAL;
	LOAN_GOODS_DIFF = AMT_CREDIT - AMT_GOODS_PRICE;

	/* Clean up outliers */
	if EMPLOYED_YEARS > 100 then EMPLOYED_YEARS = .;

	/* Final variables for modeling */
	keep SK_ID_CURR TARGET AGE_YEARS EMPLOYED_YEARS AMT_ANNUITY 
		 CREDIT_INCOME_RATIO ANNUITY_INCOME_RATIO LOAN_GOODS_DIFF;
run;


/* ---------------------------------------------
   STEP 3: Train Logistic Regression Model
--------------------------------------------- */
proc logistic data=app_train_clean descending outmodel=model_out;
	model TARGET = AGE_YEARS EMPLOYED_YEARS CREDIT_INCOME_RATIO 
				   ANNUITY_INCOME_RATIO LOAN_GOODS_DIFF AMT_ANNUITY;
	output out=predicted p=prob_default;
run;


/* -----------------------------------------------
   STEP 4: Segment Clients in Training Set 
------------------------------------------------ */
data risk_segmented;
	set predicted;
	length RISK_SEGMENT $15;

	if prob_default >= 0.2 then RISK_SEGMENT = "High Risk";
	else if prob_default >= 0.1 then RISK_SEGMENT = "Medium Risk";
	else RISK_SEGMENT = "Low Risk";
run;

proc freq data=risk_segmented;
	tables RISK_SEGMENT;
run;


/* -----------------------------------------------
   STEP 5: Add Bureau Features (External Credit Info)
------------------------------------------------ */
proc import datafile="/home/u64131160/home_credit_default_risk/bureau_trimmed.csv"
	out=bureau dbms=csv replace;
	getnames=yes;
run;

/* Aggregate bureau data by client */
proc sql;
	create table bureau_agg as
	select 
		SK_ID_CURR,
		sum(AMT_CREDIT_SUM) as TOTAL_CREDIT,
		sum(AMT_CREDIT_SUM_DEBT) as TOTAL_DEBT,
		sum(AMT_CREDIT_SUM_OVERDUE) as TOTAL_OVERDUE,
		count(*) as NUM_BUREAU_RECORDS,
		sum(case when CREDIT_ACTIVE = "Active" then 1 else 0 end) as NUM_ACTIVE_CREDITS
	from bureau
	group by SK_ID_CURR;
quit;

/* Join with training data */
proc sql;
	create table app_train_enriched as
	select a.*, b.TOTAL_CREDIT, b.TOTAL_DEBT, b.TOTAL_OVERDUE, 
		   b.NUM_BUREAU_RECORDS, b.NUM_ACTIVE_CREDITS
	from app_train_clean as a
	left join bureau_agg as b
	on a.SK_ID_CURR = b.SK_ID_CURR;
quit;


/* -----------------------------------------------------
   STEP 6: Feature Engineering for Scoring Test Dataset
----------------------------------------------------- */
data app_test_clean;
	set app_test;

	/* Same transformations as training */
	AGE_YEARS = -DAYS_BIRTH / 365;
	EMPLOYED_YEARS = ifn(DAYS_EMPLOYED in (365243, .), ., -DAYS_EMPLOYED / 365);
	CREDIT_INCOME_RATIO = AMT_CREDIT / AMT_INCOME_TOTAL;
	ANNUITY_INCOME_RATIO = AMT_ANNUITY / AMT_INCOME_TOTAL;
	LOAN_GOODS_DIFF = AMT_CREDIT - AMT_GOODS_PRICE;

	if EMPLOYED_YEARS > 100 then EMPLOYED_YEARS = .;

	keep SK_ID_CURR AGE_YEARS EMPLOYED_YEARS AMT_ANNUITY 
		 CREDIT_INCOME_RATIO ANNUITY_INCOME_RATIO LOAN_GOODS_DIFF;
run;


/* -----------------------------------------
   STEP 7: Score Test Set Using Saved Model
----------------------------------------- */
proc logistic inmodel=model_out;
	score data=app_test_clean out=app_test_scored;
run;


/* ----------------------------------------------
   STEP 8: Merge IDs Back Into Scored Data
---------------------------------------------- */
proc sort data=app_test_clean; by SK_ID_CURR; run;
proc sort data=app_test_scored; by SK_ID_CURR; run;

data app_test_scored_with_id;
	merge app_test_clean (keep=SK_ID_CURR)
	      app_test_scored;
	by SK_ID_CURR;
run;


/* ---------------------------------------------------
   STEP 9: Segment Test Clients & Assign Strategies
--------------------------------------------------- */
data app_test_final;
	set app_test_scored_with_id;
	length RISK_SEGMENT $15 COLLECTION_STRATEGY $100;

	if P_1 >= 0.2 then RISK_SEGMENT = "High Risk";
	else if P_1 >= 0.1 then RISK_SEGMENT = "Medium Risk";
	else RISK_SEGMENT = "Low Risk";

	if RISK_SEGMENT = "High Risk" then COLLECTION_STRATEGY = "Call within 24h + offer payment plan";
	else if RISK_SEGMENT = "Medium Risk" then COLLECTION_STRATEGY = "SMS + call after 7 days";
	else COLLECTION_STRATEGY = "Email reminder only";
run;


/* ----------------------------------------
   STEP 10: Export Final Scored Dataset
------------------------------------------ */
proc export data=app_test_final
	outfile="/home/u64131160/home_credit_default_risk/test_clients_scored.csv"
	dbms=csv
	replace;
run;

/* Export modeling dataset */
proc export data=app_train_clean
	outfile="/home/u64131160/home_credit_default_risk/app_train_clean.csv"
	dbms=csv
	replace;
run;
