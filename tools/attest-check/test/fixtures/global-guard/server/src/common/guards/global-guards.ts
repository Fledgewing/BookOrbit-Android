import { AppAttestGuard } from '../../modules/app-attest/app-attest.guard';
import { JwtAuthGuard } from './jwt-auth.guard';

export const GLOBAL_GUARDS = [JwtAuthGuard, AppAttestGuard] as const;
