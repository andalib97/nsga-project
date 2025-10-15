function [E_vr_next, E_aa_next, P_diesel, unmet, flows] = dispatch_step( ...
    P_gen, P_load, ...
    E_vr, VR_E, VR_P, eta_vr_ch, eta_vr_dis, vr_parasitic_kw, ...
    E_aa, AA_E, AA_P, eta_aa_ch, eta_aa_dis, aa_parasitic_kw, ...
    DG_P, diesel, scheme, dt, varargin)
% DISPATCH_STEP (rev C)  One-timestep dispatch + storage update with flows.
%
% Inputs (scalars for this step):
%   P_gen  : renewable power available (kW)  [PV + Wind] BEFORE parasitics
%   P_load : electrical load (kW) average during this step
%   ...    : storage states/caps/efficiencies as before
%   DG_P   : diesel generator power rating (kW)
%   diesel : struct, optional fields:
%              .diesel_min_on_kw >=0   minimum online power when deficit>0 (default 0)
%   scheme : 1=VRFB-first, 2=AA-CAES-first, 3=Balanced-by-SOC
%   dt     : step length (h)
%   varargin{1} (optional): flags struct for start-up gating:
%              .c_prev_any  (logical) 1 if any storage was discharging in t-1
%              .aa_ready    (logical) if you manage AA-CAES readiness yourself
%
% Outputs:
%   E_vr_next, E_aa_next : next-step energies (kWh) in [0, cap]
%   P_diesel             : diesel power used this step (kW)
%   unmet                : unmet load after diesel (kW)
%   flows                : struct of per-step powers (kW):
%       .P_ren_to_load  - direct renewables serving load
%       .P_vr_ch/dis    - VRFB charge / discharge
%       .P_aa_ch/dis    - AA-CAES charge / discharge
%       .P_curtail      - curtailed renewables after charging
%       .P_diesel       - diesel power (same as P_diesel)
%       .P_gen_net      - renewables after (static) parasitics
%       .c_active       - 1 if any storage discharged this step
%       .aa_blocked     - 1 if AA-CAES discharge was blocked by start-up rule

% ---------- Sanitize inputs ----------
P_gen  = max(0, double(P_gen));
P_load = max(0, double(P_load));
DG_P   = max(0, double(DG_P));
VR_E   = max(0, double(VR_E));  VR_P = max(0, double(VR_P));
AA_E   = max(0, double(AA_E));  AA_P = max(0, double(AA_P));
eta_vr_ch = max(0, double(eta_vr_ch)); eta_vr_dis = max(0, double(eta_vr_dis));
eta_aa_ch = max(0, double(eta_aa_ch)); eta_aa_dis = max(0, double(eta_aa_dis));
vr_parasitic_kw = max(0, double(vr_parasitic_kw));
aa_parasitic_kw = max(0, double(aa_parasitic_kw));
dt = max(eps, double(dt));  % avoid zero-division

% Optional flags (start-up gating)
flags = struct('c_prev_any', true, 'aa_ready', true); % default: available
if ~isempty(varargin) && isstruct(varargin{1})
    f = varargin{1};
    if isfield(f,'c_prev_any') && ~isempty(f.c_prev_any), flags.c_prev_any = logical(f.c_prev_any); end
    if isfield(f,'aa_ready')    && ~isempty(f.aa_ready),  flags.aa_ready  = logical(f.aa_ready);  end
end

% Optional AA-CAES start-up delay from tech (handled by caller via flags if > dt)
aa_startup_h = 0;
if isstruct(diesel) && isfield(diesel,'aa_startup_h') && ~isempty(diesel.aa_startup_h)
    aa_startup_h = max(0, double(diesel.aa_startup_h));
end

% ---------- Parasitics & base split ----------
% NOTE: We keep parasitics as a static deduction like your rev B (papers often
% treat auxiliaries as extra net load). If you later want parasitics only when
% devices are active, pass zeros here and add them into P_load in the caller.
P_parasitics = max(0, vr_parasitic_kw + aa_parasitic_kw);
P_net_gen    = max(0, P_gen - P_parasitics);

% Renewables first supply the load (direct), then any remainder is surplus
P_ren_to_load = min(P_net_gen, P_load);
surplus       = max(0, P_net_gen - P_load);     % leftover RE to possibly charge
deficit       = max(0, P_load - P_net_gen);     % remaining load after direct RE

% ---------- Initialize ----------
P_vr_ch = 0;  P_vr_dis = 0;
P_aa_ch = 0;  P_aa_dis = 0;
P_diesel = 0;  P_curtail = 0;
aa_blocked = false;

% ---------- CHARGING (use surplus) ----------
if surplus > 0
    % Prioritize charging the lower SOC device first
    soc_vr = safe_ratio(E_vr, VR_E);
    soc_aa = safe_ratio(E_aa, AA_E);
    if soc_vr < soc_aa
        [E_vr, P_vr_ch, surplus] = charge_device(E_vr, VR_E, eta_vr_ch, surplus, VR_P, dt);
        [E_aa, P_aa_ch, surplus] = charge_device(E_aa, AA_E, eta_aa_ch, surplus, AA_P, dt);
    else
        [E_aa, P_aa_ch, surplus] = charge_device(E_aa, AA_E, eta_aa_ch, surplus, AA_P, dt);
        [E_vr, P_vr_ch, surplus] = charge_device(E_vr, VR_E, eta_vr_ch, surplus, VR_P, dt);
    end
    % Any leftover surplus after charging is curtailed
    P_curtail = max(0, surplus);
end

% ---------- DISCHARGING (cover remaining deficit) ----------
if deficit > 0
    % AA-CAES start-up gating (minimal per-step version):
    % If a start-up lag is desired and no storage was active previously (c_prev_any=0),
    % block AA-CAES discharge this step unless flags.aa_ready is set by caller.
    allow_AA = true;
    if aa_startup_h > 0
        % minimal: require at least previous step active or explicit readiness
        allow_AA = flags.c_prev_any || flags.aa_ready;
        if ~allow_AA, aa_blocked = true; end
    end

    switch scheme
        case 1 % VRFB-first
            [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
            if allow_AA
                [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
            end
        case 2 % AA-CAES-first
            if allow_AA
                [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
            end
            [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
        case 3 % Balanced by SOC (discharge higher SOC first)
            soc_vr = safe_ratio(E_vr, VR_E);
            soc_aa = safe_ratio(E_aa, AA_E);
            if soc_vr >= soc_aa
                [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
                if allow_AA
                    [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
                end
            else
                if allow_AA
                    [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
                end
                [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
            end
        otherwise
            % Fallback = Balanced
            soc_vr = safe_ratio(E_vr, VR_E);
            soc_aa = safe_ratio(E_aa, AA_E);
            if soc_vr >= soc_aa
                [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
                if allow_AA
                    [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
                end
            else
                if allow_AA
                    [E_aa, P_aa_dis, deficit] = discharge_device(E_aa, AA_E, eta_aa_dis, deficit, AA_P, dt);
                end
                [E_vr, P_vr_dis, deficit] = discharge_device(E_vr, VR_E, eta_vr_dis, deficit, VR_P, dt);
            end
    end
end

% ---------- Diesel covers remaining deficit (with optional min-online) ----------
diesel_min = 0;
if isstruct(diesel) && isfield(diesel,'diesel_min_on_kw') && ~isempty(diesel.diesel_min_on_kw)
    diesel_min = max(0, double(diesel.diesel_min_on_kw));
end

if deficit > 0
    % Use what's needed up to DG_P; if deficit exists, enforce minimum online power
    P_diesel = min(deficit, DG_P);
    P_diesel = max(P_diesel, min(diesel_min, DG_P)); % minimum only if deficit present
    deficit  = max(0, deficit - P_diesel);
else
    % Optional: keep diesel online even when no deficit
    % P_diesel = min(diesel_min, DG_P);
end

% Any leftover deficit is unmet load
unmet = max(0, deficit);

% ---------- State updates (saturating) ----------
E_vr_next = clamp_energy(E_vr + eta_vr_ch*P_vr_ch*dt - (1/eta_vr_dis)*P_vr_dis*dt, 0, VR_E);
E_aa_next = clamp_energy(E_aa + eta_aa_ch*P_aa_ch*dt - (1/eta_aa_dis)*P_aa_dis*dt, 0, AA_E);

% ---------- Flows struct for energy accounting ----------
flows = struct();
flows.P_ren_to_load = P_ren_to_load;
flows.P_vr_ch       = P_vr_ch;
flows.P_vr_dis      = P_vr_dis;
flows.P_aa_ch       = P_aa_ch;
flows.P_aa_dis      = P_aa_dis;
flows.P_curtail     = P_curtail;
flows.P_diesel      = P_diesel;
flows.P_gen_net     = P_net_gen;
flows.c_active      = (P_vr_dis > 0) || (P_aa_dis > 0);
flows.aa_blocked    = aa_blocked;

end

% ============================ Helpers ===================================
function r = safe_ratio(e, emax)
if emax <= 0, r = 0; else, r = max(0, min(1, e / emax)); end
end

function [E, Pch, surplus] = charge_device(E, Emax, eta_ch, surplus, P_cap, dt)
if E >= Emax || surplus <= 0 || P_cap <= 0 || eta_ch <= 0
    Pch = 0; return;
end
P_headroom = (Emax - E) / max(eta_ch*dt, eps);  % kW you can accept without exceeding cap
Pch = max(0, min([surplus, P_cap, P_headroom]));
E = E + eta_ch * Pch * dt;
surplus = max(0, surplus - Pch);
end

function [E, Pdis, deficit] = discharge_device(E, Emax, eta_dis, deficit, P_cap, dt)
if E <= 0 || deficit <= 0 || P_cap <= 0 || eta_dis <= 0
    Pdis = 0; return;
end
% Deliverable power limited by rating and available energy over dt:
P_energy = eta_dis * E / max(dt, eps);          % max deliverable power (kW)
Pdis = max(0, min([deficit, P_cap, P_energy]));
E = E - (1/eta_dis) * Pdis * dt;
deficit = max(0, deficit - Pdis);
end

function Eo = clamp_energy(Ei, Emin, Emax)
Eo = min(max(Ei, Emin), Emax);
end
