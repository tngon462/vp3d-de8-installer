# Bo cai DE8 v1.0.0 - Windows 10 / PowerShell 5.1

## Tai va kiem tra
Release cong khai: https://github.com/tngon462/vp3d-de8-installer/releases/tag/v1.0.0
URL ZIP va SHA256: CHO DE 16 DIEN TREN RELEASE.
Tai ZIP bo cai dinh kem, khong dung Source code ZIP. Khong can Git/repo nguon.
Lay SHA256 tu manifest/Release chinh thuc qua HTTPS; dung lai neu chua co.
SHA256 khong thay the nguon tin cay.

    $zip = Join-Path $env:USERPROFILE 'Downloads\vp3d-de8-installer-1.0.0.zip'
    $expected = '<SHA256 ZIP do nha phat hanh cong bo>'
    if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'Chua co SHA256 hop le' }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw 'SHA256 mismatch' }
    $destination = Join-Path $env:USERPROFILE 'Downloads\DE8-1.0.0'
    Expand-Archive -LiteralPath $zip -DestinationPath $destination
    Set-Location $destination

Neu ZIP co thu muc bao ngoai, chuyen den noi chua install-de8-https.ps1.
Doi chieu VERSION.txt va CHANGELOG.md.

## Chuan bi va cai dat
Nguoi van hanh cung cap HTTPS origin, file khoa da dang ky va thu muc agent
hien co. Khong tao/ghi de khoa dang hoat dong. File khoa/cookie nam ngoai
bo cai, chi tai khoan van hanh co quyen doc. Khong gui khoa, cookie, journal,
backup hay install-state vao chat/repo. Thay gia tri mau truoc khi chay:

    $server = 'https://<origin-do-nguoi-van-hanh-cung-cap>'
    $tokenPath = '<file-khoa-hien-co>'
    $installDir = '<thu-muc-chua-agent-hien-co>'
    $cookiePath = '<file-cookie-phien-dang-nhap-con-han>'
    Get-FileHash .\de8-agent.ps1 -Algorithm SHA256
    Get-Content .\agent.sha256
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-de8-https.ps1 -Server $server -TokenPath $tokenPath -InstallDir $installDir

Chay cung tai khoan voi agent cu; khong chon thu muc moi neu agent dang chay
o noi khac. Installer kiem hash, doi heartbeat xac nhan, backup timestamp va
chay agent an. Khong reboot, doi firewall hay dung Chrome/POS/in tem.
Chi ho tro agent cu chay powershell.exe -File. Neu dung service/Task Scheduler,
nguoi van hanh can dung co che tu khoi dong truoc. Khong chay hai agent.
Neu FAIL sau khi co install-state.json thi rollback; giu journal chong trung.

## Verify va rollback
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify-de8-https.ps1 -InstallDir $installDir -SessionCookiePath $cookiePath

PASS ALL (exit 0): heartbeat that, ONLINE 5 chu ky lastSeen tang, mot chan doan
chi doc hostname/so o dia co ACK/ket qua khop, OFFLINE 30 giay roi tu ONLINE.
FAIL exit 1. Verify tam dung transport DE8 bang transport.pause, khong ngat
mang POS. Cho 45 giay drain/TTL truoc khi do 30 giay. Neu bi kill, xoa
transport.pause trong installDir. Khong verify dong thoi; hang doi phai ranh.

Chi chay lenh sau khi can khoi phuc:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rollback-de8.ps1 -InstallDir $installDir

Rollback kiem hash backup, khoi phuc agent cu theo trang thai truoc cai; chua
co agent cu thi go file moi. Backup/journal giu tai may. PASS xac nhan
file/process; ket noi agent cu can kiem rieng.

## Kiem tra cap nhat: chi thong bao
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\check-update.ps1 -EveryHours 24 -PackagePath $zip

Manifest mac dinh:
https://raw.githubusercontent.com/tngon462/vp3d-de8-installer/main/manifest.json

Moi lan goi chi kiem tra neu da qua EveryHours (mac dinh 24). Script khong tao
lich. Nguoi van hanh co the dung Task Scheduler goi lenh moi gio, dung cung
RuntimeDir. Co the doi -ManifestUrl (HTTPS), -RuntimeDir va -PackagePath.
Runtime mac dinh ben canh script, can quyen ghi. Lan loi cung cho den ky sau.
Chi doc manifest, so version/SHA256, bao ban moi kem URL/SHA256; khong tai ZIP,
khong chay hay cai ban moi. Bo qua PackagePath thi dung hash manifest cuc bo
neu co; chua co hash bao UNVERIFIED. Cung version khac hash bao
PACKAGE_HASH_MISMATCH. Log ngan: runtime/check-update.log.
Exit 0 thanh cong/chua den lich; exit 1 loi.

Nha phat hanh dat manifest.json o goc nhanh main repo cong khai, dien url/sha256 cua ZIP cuoi cung va cong bo manifest ben ngoai
ZIP de tranh hash tu tham chieu. Khong dong goi runtime, khoa, cookie,
journal, backup hay install-state. Package-commit la SHA commit noi dung;
commit metadata ke tiep ghi SHA do (commit khong the chua SHA cua chinh no).
