function build_weipa_resource_file(year, lat, lon, outFile)
% Fetch hourly GHI (ALLSKY_SFC_SW_DWN) and 10 m wind (WS10M) from NASA POWER
% and save as 'weipa_solar_wind.mat' with variables GHI (0..~1) and wind_speed (m/s).

if nargin < 1, year = 2019; end
if nargin < 2, lat  = -12.68; end
if nargin < 3, lon  = 141.92; end
if nargin < 4, outFile = 'weipa_solar_wind.mat'; end

base = 'https://power.larc.nasa.gov/api/temporal/hourly/point';
params = ['parameters=ALLSKY_SFC_SW_DWN,WS10M&community=RE&',...
          sprintf('latitude=%.4f&longitude=%.4f&',lat,lon),...
          sprintf('start=%04d0101&end=%04d1231&',year,year),...
          'format=JSON&time-standard=LST'];  % or time-standard=UTC
url = sprintf('%s?%s', base, params);

S = webread(url);
P = S.properties.parameter;

% POWER returns a struct keyed by timestamps 'YYYYMMDDHH' -> value
fn = fieldnames(P.ALLSKY_SFC_SW_DWN);
n  = numel(fn);
ghi_Wm2 = zeros(n,1); ws = zeros(n,1);
for i = 1:n
    ghi_Wm2(i) = P.ALLSKY_SFC_SW_DWN.(fn{i});
    ws(i)      = P.WS10M.(fn{i});
end

% Convert to what your model expects:
% HRES scripts use PV_gen = PV_kW * GHI_factor; make factor from W/m^2 -> kW/m^2
GHI         = max(0, ghi_Wm2 / 1000);   % [kW/m^2 equivalent]
wind_speed  = ws;                        % [m/s]

save(outFile, 'GHI', 'wind_speed');
fprintf('Saved %s (%d hours)\n', outFile, numel(GHI));
end
