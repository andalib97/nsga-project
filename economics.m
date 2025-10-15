function [CC, breakdown] = economics(design, costs)
% ECONOMICS (rev B)  Capital cost objective for the HRES sizing problem.
%
% Primary output:
%   CC          - Total capital cost [$] (scalar)
% Optional:
%   breakdown   - struct with per-subsystem costs (for debugging/plots)
%
% Baseline is a linear sum over capacities, as in the reference papers.
% Optional multipliers (EPC/contingency) and scale exponents are supported
% but default to identity so results remain paper-consistent.

% --------- guards & required fields --------------------------------------
req_design = {'PV_kW','WT_kW','AA_E','AA_P','VR_E','VR_P','DG_P'};
req_costs  = {'U_pv_kw','U_wt_kw','U_aa_e_kwh','U_aa_p_kw','U_vr_e_kwh','U_vr_p_kw','U_dg_kw'};
local_assert_fields(design, req_design, 'design');
local_assert_fields(costs,  req_costs,  'costs');

% Clamp to nonnegative (defensive)
PV_kW = max(0, double(design.PV_kW));
WT_kW = max(0, double(design.WT_kW));
AA_E  = max(0, double(design.AA_E));
AA_P  = max(0, double(design.AA_P));
VR_E  = max(0, double(design.VR_E));
VR_P  = max(0, double(design.VR_P));
DG_P  = max(0, double(design.DG_P));

% Unit costs (must be finite)
U_pv_kw    = local_pos(costs.U_pv_kw,    'U_pv_kw');
U_wt_kw    = local_pos(costs.U_wt_kw,    'U_wt_kw');
U_aa_e     = local_pos(costs.U_aa_e_kwh, 'U_aa_e_kwh');
U_aa_p     = local_pos(costs.U_aa_p_kw,  'U_aa_p_kw');
U_vr_e     = local_pos(costs.U_vr_e_kwh, 'U_vr_e_kwh');
U_vr_p     = local_pos(costs.U_vr_p_kw,  'U_vr_p_kw');
U_dg_kw    = local_pos(costs.U_dg_kw,    'U_dg_kw');

% --------- optional knobs (default = paper's linear model) ---------------
% EPC/contingency multipliers (1.0 = no effect)
EPC_factor        = local_get(costs,'EPC_factor',1.0);          % e.g., 1.10
contingency_frac  = local_get(costs,'contingency_frac',0.0);    % e.g., 0.1

% Gentle economies-of-scale exponents (1.0 = linear, paper-consistent)
% (If you don't want EOS, leave at 1.0)
k_pv = local_get(costs,'k_scale_pv',1.0);
k_wt = local_get(costs,'k_scale_wt',1.0);
k_aaE= local_get(costs,'k_scale_aa_e',1.0);
k_aaP= local_get(costs,'k_scale_aa_p',1.0);
k_vrE= local_get(costs,'k_scale_vr_e',1.0);
k_vrP= local_get(costs,'k_scale_vr_p',1.0);
k_dg = local_get(costs,'k_scale_dg',1.0);

% Optional minimal fixed costs (defaults 0)
F_pv = local_get(costs,'F_pv',0);
F_wt = local_get(costs,'F_wt',0);
F_aa = local_get(costs,'F_aa',0);
F_vr = local_get(costs,'F_vr',0);
F_dg = local_get(costs,'F_dg',0);

% --------- component CAPEX (linear by default) --------------------------
C_pv = F_pv + U_pv_kw * (PV_kW^k_pv);
C_wt = F_wt + U_wt_kw * (WT_kW^k_wt);

C_aa = F_aa + U_aa_e  * (AA_E^k_aaE) + U_aa_p * (AA_P^k_aaP);
C_vr = F_vr + U_vr_e  * (VR_E^k_vrE) + U_vr_p * (VR_P^k_vrP);

C_dg = F_dg + U_dg_kw * (DG_P^k_dg);

% Sum & apply EPC/contingency
CC_base = C_pv + C_wt + C_aa + C_vr + C_dg;
CC_EPC  = EPC_factor * CC_base;
CC      = CC_EPC * (1 + contingency_frac);

% Optional breakdown
if nargout > 1
    breakdown = struct('C_pv',C_pv,'C_wt',C_wt,'C_aa',C_aa,'C_vr',C_vr,'C_dg',C_dg, ...
                       'CC_base',CC_base,'CC_EPC',CC_EPC,'CC',CC);
end
end

% ------------------------ local helpers ----------------------------------
function local_assert_fields(s, names, sname)
missing = names(~isfield(s, names));
if ~isempty(missing)
    error('economics:%s_missing', sname, ...
        'Missing field(s) in %s: %s', sname, strjoin(missing, ', '));
end
end

function v = local_get(s, f, def)
if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = def; end
end

function u = local_pos(val, name)
u = double(val);
if ~isfinite(u) || u < 0
    error('economics:bad_unit_cost','Unit cost %s must be finite and >=0 (got %g)', name, val);
end
end
